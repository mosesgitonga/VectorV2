defmodule Vector.Payments do
  import Ecto.Query
  alias Vector.Repo
  alias Vector.Payments.{Transaction, Paystack}
  alias Vector.Tournaments

  @platform_fee_percent Decimal.new("0.15")

  # ── Entry fee ──────────────────────────────────────────────────────────────

  def create_entry_fee_transaction(user, tournament) do
    reference = unique_reference()
    amount = tournament.entry_fee
    amount_kobo = to_kobo(amount)

    {access_code, paystack_meta} =
      case Paystack.initialize_transaction(user.email, amount_kobo, reference, %{
             tournament_id: tournament.id,
             user_id: user.id,
             type: "entry_fee"
           }) do
        {:ok, response} ->
          {get_in(response, ["data", "access_code"]), response["data"]}

        {:error, _reason} ->
          {nil, %{}}
      end

    %Transaction{}
    |> Transaction.changeset(%{
      user_id: user.id,
      tournament_id: tournament.id,
      type: "entry_fee",
      amount: amount,
      paystack_reference: reference,
      paystack_access_code: access_code,
      metadata: %{paystack: paystack_meta}
    })
    |> Repo.insert()
  end

  def handle_webhook(payload, signature) do
    with true <- verify_signature(payload, signature),
         %{"event" => event, "data" => data} <- Jason.decode!(payload) do
      process_event(event, data)
    else
      false -> {:error, :invalid_signature}
      _ -> {:error, :invalid_payload}
    end
  end

  def confirm_payment(reference) do
    with {:ok, response} <- Paystack.verify_transaction(reference),
         %{"data" => %{"status" => "success"}} <- response do
      case Repo.get_by(Transaction, paystack_reference: reference) do
        nil ->
          {:error, :transaction_not_found}

        transaction ->
          with {:ok, transaction} <-
                 transaction |> Transaction.confirm_changeset(reference) |> Repo.update() do
            Tournaments.mark_participant_paid(transaction.tournament_id, transaction.user_id)
            Tournaments.confirm_payment_and_start(transaction.tournament_id)
            {:ok, transaction}
          end
      end
    else
      _ -> {:error, :payment_not_successful}
    end
  end

  def pay_winner(winner_id, tournament, prize_amount) do
    reference = unique_reference()

    %Transaction{}
    |> Transaction.changeset(%{
      user_id: winner_id,
      tournament_id: tournament.id,
      type: "payout",
      amount: prize_amount,
      paystack_reference: reference,
      metadata: %{note: "Tournament prize payout"}
    })
    |> Repo.insert()
  end

  def refund_tournament_participants(tournament) do
    Transaction
    |> where(tournament_id: ^tournament.id, type: "entry_fee", status: "success")
    |> Repo.all()
    |> Enum.each(fn tx ->
      amount_kobo = to_kobo(tx.amount)

      case Paystack.refund(tx.paystack_reference, amount_kobo) do
        {:ok, _} ->
          tx |> Transaction.refund_changeset() |> Repo.update()

        {:error, _} ->
          :noop
      end
    end)
  end

  def list_transactions(user_id) do
    Transaction
    |> where(user_id: ^user_id)
    |> order_by([t], desc: t.inserted_at)
    |> preload(:tournament)
    |> Repo.all()
  end

  def list_all_transactions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    Transaction
    |> order_by([t], desc: t.inserted_at)
    |> preload([:user, :tournament])
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def total_revenue do
    Transaction
    |> where(type: "entry_fee", status: "success")
    |> Repo.aggregate(:sum, :amount)
    |> Decimal.mult(@platform_fee_percent)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp process_event("charge.success", data) do
    reference = data["reference"]
    confirm_payment(reference)
  end

  defp process_event(_event, _data), do: :ok

  defp verify_signature(payload, signature) do
    secret = Application.fetch_env!(:vector, :paystack_secret_key)

    expected =
      :crypto.mac(:hmac, :sha512, secret, payload)
      |> Base.encode16(case: :lower)

    Plug.Crypto.secure_compare(expected, signature)
  end

  defp unique_reference do
    "VEC-#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end

  defp to_kobo(amount) do
    amount |> Decimal.mult(100) |> Decimal.to_integer()
  end
end
