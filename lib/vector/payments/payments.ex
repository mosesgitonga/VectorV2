defmodule Vector.Payments do
  import Ecto.Query
  require Logger
  alias Vector.Repo
  alias Vector.Accounts.User
  alias Vector.Payments.{Transaction, Paystack}
  alias Vector.Tournaments

  @platform_fee_percent   Decimal.new("0.15")
  @min_deposit            Decimal.new("30")
  @max_deposit            Decimal.new("5000")
  @min_withdrawal         Decimal.new("10")
  @max_withdrawal         Decimal.new("5000")
  @withdrawal_window_secs 600   # 10-minute rolling window

  # ── Wallet deposit ─────────────────────────────────────────────────────────

  def create_deposit(user, amount) do
    amount_dec = Decimal.new("#{amount}")

    cond do
      Decimal.lt?(amount_dec, @min_deposit) ->
        {:error, "Minimum deposit is KES 30"}

      Decimal.gt?(amount_dec, @max_deposit) ->
        {:error, "Maximum deposit is KES 5,000"}

      true ->
        reference = unique_reference()
        amount_kobo = to_kobo(amount_dec)

        {access_code, paystack_meta} =
          case Paystack.initialize_transaction(user.email, amount_kobo, reference, %{
                 user_id: user.id,
                 type: "deposit"
               }) do
            {:ok, response} -> {get_in(response, ["data", "access_code"]), response["data"]}
            {:error, _} -> {nil, %{}}
          end

        %Transaction{}
        |> Transaction.changeset(%{
          user_id: user.id,
          type: "deposit",
          amount: amount_dec,
          paystack_reference: reference,
          paystack_access_code: access_code,
          metadata: %{paystack: paystack_meta}
        })
        |> Repo.insert()
    end
  end

  # ── Entry fee from wallet ──────────────────────────────────────────────────

  def deduct_entry_fee(user, tournament) do
    Repo.transaction(fn ->
      fresh_user = from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE") |> Repo.one!()

      case fresh_user |> User.deduct_balance_changeset(tournament.entry_fee) |> Repo.update() do
        {:ok, _updated_user} ->
          %Transaction{}
          |> Transaction.changeset(%{
            user_id: user.id,
            tournament_id: tournament.id,
            type: "entry_fee",
            amount: tournament.entry_fee,
            paystack_reference: unique_reference(),
            status: "success",
            metadata: %{note: "Deducted from wallet"}
          })
          |> Repo.insert()
          |> case do
            {:ok, tx} -> tx
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  # ── Wallet withdrawal ──────────────────────────────────────────────────────

  def create_withdrawal(user, amount) do
    amount_dec = Decimal.new("#{amount}")

    cond do
      is_nil(user.phone_number) or user.phone_number == "" ->
        {:error, :no_phone_number}

      Decimal.lt?(amount_dec, @min_withdrawal) ->
        {:error, "Minimum withdrawal is KES #{@min_withdrawal}"}

      Decimal.gt?(amount_dec, @max_withdrawal) ->
        {:error, "Maximum single withdrawal is KES #{@max_withdrawal}"}

      true ->
        # Phase 1: lock user row, check balance + rate limit, deduct, record pending tx.
        # HTTP call to Paystack happens OUTSIDE the DB transaction.
        case reserve_withdrawal(user, amount_dec) do
          {:ok, tx} ->
            case send_paystack_transfer(user, amount_dec, tx) do
              {:ok, updated_tx} ->
                {:ok, updated_tx}

              {:error, reason} ->
                reverse_withdrawal(user.id, amount_dec, tx)
                {:error, reason}
            end

          {:error, _} = err ->
            err
        end
    end
  end

  defp reserve_withdrawal(user, amount_dec) do
    Repo.transaction(fn ->
      fresh_user =
        from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE")
        |> Repo.one!()

      if Decimal.lt?(fresh_user.balance, amount_dec) do
        Repo.rollback(:insufficient_balance)
      end

      already_withdrawn = withdrawn_in_window(fresh_user.id)
      projected_total   = Decimal.add(already_withdrawn, amount_dec)

      if Decimal.gt?(projected_total, @max_withdrawal) do
        remaining = Decimal.sub(@max_withdrawal, already_withdrawn) |> Decimal.max(Decimal.new("0"))
        Repo.rollback({:rate_limited, remaining})
      end

      with {:ok, _} <- fresh_user |> User.deduct_balance_changeset(amount_dec) |> Repo.update(),
           {:ok, tx} <-
             %Transaction{}
             |> Transaction.changeset(%{
               user_id: fresh_user.id,
               type: "withdrawal",
               amount: amount_dec,
               paystack_reference: unique_reference(),
               status: "pending",
               metadata: %{"phone" => user.phone_number}
             })
             |> Repo.insert() do
        tx
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp send_paystack_transfer(user, _amount_dec, tx) do
    amount_kobo = to_kobo(tx.amount)
    name = user.name || user.email

    with {:ok, recipient_resp} <- Paystack.create_mobile_money_recipient(name, user.phone_number),
         recipient_code when is_binary(recipient_code) <-
           get_in(recipient_resp, ["data", "recipient_code"]),
         {:ok, transfer_resp} <-
           Paystack.initiate_transfer(amount_kobo, recipient_code, "Vector wallet withdrawal") do
      transfer_code = get_in(transfer_resp, ["data", "transfer_code"])
      transfer_status = get_in(transfer_resp, ["data", "status"])

      tx_status = if transfer_status == "success", do: "success", else: "pending"

      updated_tx =
        tx
        |> Ecto.Changeset.change(
          status: tx_status,
          metadata: Map.merge(tx.metadata || %{}, %{"transfer_code" => transfer_code})
        )
        |> Repo.update!()

      Logger.info("Paystack transfer initiated", user_id: user.id, transfer_code: transfer_code, status: tx_status)
      {:ok, updated_tx}
    else
      nil ->
        {:error, "Could not create transfer recipient. Check phone number."}

      {:error, %{"message" => msg}} ->
        Logger.error("Paystack transfer failed", user_id: user.id, reason: msg)
        {:error, msg}

      {:error, reason} ->
        Logger.error("Paystack transfer failed", user_id: user.id, reason: inspect(reason))
        {:error, "Transfer failed. Please try again."}
    end
  end

  defp reverse_withdrawal(user_id, amount_dec, tx) do
    Logger.warning("Reversing failed withdrawal reservation", user_id: user_id, tx_id: tx.id)

    Repo.transaction(fn ->
      fresh_user =
        from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE")
        |> Repo.one!()

      fresh_user |> User.credit_balance_changeset(amount_dec) |> Repo.update!()
      tx |> Transaction.fail_changeset() |> Repo.update!()
    end)
  end

  # Returns the remaining KES a user can withdraw in the current window.
  def withdrawal_limit_remaining(user_id) do
    already = withdrawn_in_window(user_id)
    Decimal.sub(@max_withdrawal, already) |> Decimal.max(Decimal.new("0"))
  end

  # ── Webhook / confirm ──────────────────────────────────────────────────────

  def handle_webhook(payload, signature) do
    with true <- verify_signature(payload, signature),
         %{"event" => event, "data" => data} <- Jason.decode!(payload) do
      Logger.info("Paystack webhook received", event: event)
      process_event(event, data)
    else
      false ->
        Logger.warning("Paystack webhook: invalid signature")
        {:error, :invalid_signature}
      _ ->
        Logger.warning("Paystack webhook: invalid payload")
        {:error, :invalid_payload}
    end
  end

  def confirm_payment(reference) do
    with {:ok, response} <- Paystack.verify_transaction(reference),
         %{"data" => %{"status" => "success"}} <- response do
      # Atomic update — only transitions pending → success.
      # Guards against duplicate webhook deliveries and concurrent /verify calls.
      {count, [transaction]} =
        Transaction
        |> where(paystack_reference: ^reference, status: "pending")
        |> select([t], t)
        |> Repo.update_all(set: [status: "success"])

      case count do
        0 ->
          # Already confirmed (idempotent) — succeed silently
          case Repo.get_by(Transaction, paystack_reference: reference) do
            nil -> {:error, :transaction_not_found}
            tx  -> {:ok, tx}
          end

        1 ->
          handle_confirmed_transaction(transaction)
          {:ok, transaction}
      end
    else
      _ -> {:error, :payment_not_successful}
    end
  end

  # ── Payout / refund ────────────────────────────────────────────────────────

  def pay_winner(winner_id, tournament, prize_amount) do
    Logger.info("Paying tournament winner", winner_id: winner_id, tournament_id: tournament.id, amount: prize_amount)
    Repo.transaction(fn ->
      user = from(u in User, where: u.id == ^winner_id, lock: "FOR UPDATE") |> Repo.one!()

      with {:ok, _} <- user |> User.credit_balance_changeset(prize_amount) |> Repo.update(),
           {:ok, tx} <-
             %Transaction{}
             |> Transaction.changeset(%{
               user_id: winner_id,
               tournament_id: tournament.id,
               type: "payout",
               amount: prize_amount,
               paystack_reference: unique_reference(),
               status: "success",
               metadata: %{note: "Tournament prize credited to wallet"}
             })
             |> Repo.insert() do
        tx
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def refund_tournament_participants(tournament) do
    transactions =
      Transaction
      |> where(tournament_id: ^tournament.id, type: "entry_fee", status: "success")
      |> Repo.all()

    # All-or-nothing: if any refund step fails the whole batch rolls back.
    Repo.transaction(fn ->
      Enum.each(transactions, fn tx ->
        user = from(u in User, where: u.id == ^tx.user_id, lock: "FOR UPDATE") |> Repo.one!()

        with {:ok, _} <- user |> User.credit_balance_changeset(tx.amount) |> Repo.update(),
             {:ok, _} <- tx |> Transaction.refund_changeset() |> Repo.update() do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
  end

  # ── Queries ────────────────────────────────────────────────────────────────

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
    |> then(&(if &1, do: Decimal.mult(&1, @platform_fee_percent), else: Decimal.new(0)))
  end

  def get_user_balance(user_id) do
    Repo.get!(User, user_id).balance
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp handle_confirmed_transaction(%{type: "deposit"} = tx) do
    Repo.transaction(fn ->
      user = from(u in User, where: u.id == ^tx.user_id, lock: "FOR UPDATE") |> Repo.one!()

      case user |> User.credit_balance_changeset(tx.amount) |> Repo.update() do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp handle_confirmed_transaction(%{type: "entry_fee"} = tx) do
    Tournaments.mark_participant_paid(tx.tournament_id, tx.user_id)
    Tournaments.confirm_payment_and_start(tx.tournament_id)
  end

  defp handle_confirmed_transaction(_tx), do: :ok

  defp process_event("charge.success", data) do
    reference = data["reference"]
    confirm_payment(reference)
  end

  defp process_event("transfer.success", data) do
    handle_transfer_event(data["transfer_code"], :success)
  end

  defp process_event("transfer.failed", %{"transfer_code" => tc}), do: handle_transfer_event(tc, :failed)
  defp process_event("transfer.reversed", %{"transfer_code" => tc}), do: handle_transfer_event(tc, :failed)

  defp process_event(_event, _data), do: :ok

  defp handle_transfer_event(transfer_code, outcome) when is_binary(transfer_code) do
    tx =
      Transaction
      |> where([t], t.type == "withdrawal" and t.status == "pending")
      |> where([t], fragment("?->>'transfer_code' = ?", t.metadata, ^transfer_code))
      |> Repo.one()

    case {tx, outcome} do
      {nil, _} ->
        :ok

      {tx, :success} ->
        tx |> Ecto.Changeset.change(status: "success") |> Repo.update()
        Logger.info("Transfer confirmed via webhook", transfer_code: transfer_code)
        :ok

      {tx, :failed} ->
        Repo.transaction(fn ->
          fresh_user =
            from(u in User, where: u.id == ^tx.user_id, lock: "FOR UPDATE")
            |> Repo.one!()

          fresh_user |> User.credit_balance_changeset(tx.amount) |> Repo.update!()
          tx |> Transaction.fail_changeset() |> Repo.update!()
        end)

        Logger.warning("Transfer failed via webhook, balance refunded", transfer_code: transfer_code)
        :ok
    end
  end

  defp handle_transfer_event(_transfer_code, _outcome), do: :ok

  defp withdrawn_in_window(user_id) do
    window_start = DateTime.utc_now() |> DateTime.add(-@withdrawal_window_secs, :second)

    Transaction
    |> where(user_id: ^user_id, type: "withdrawal")
    |> where([t], t.status in ["pending", "success"])
    |> where([t], t.inserted_at >= ^window_start)
    |> Repo.aggregate(:sum, :amount)
    |> then(&(&1 || Decimal.new("0")))
  end

  defp verify_signature(payload, signature) do
    secret = Application.fetch_env!(:vector, :paystack_secret_key)
    expected = :crypto.mac(:hmac, :sha512, secret, payload) |> Base.encode16(case: :lower)
    Plug.Crypto.secure_compare(expected, signature)
  end

  defp unique_reference do
    "VEC-#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end

  defp to_kobo(amount) do
    amount |> Decimal.mult(100) |> Decimal.to_integer()
  end
end
