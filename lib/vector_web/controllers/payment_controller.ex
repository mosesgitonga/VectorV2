defmodule VectorWeb.PaymentController do
  use VectorWeb, :controller

  alias Vector.Payments

  def webhook(conn, _params) do
    signature = List.first(get_req_header(conn, "x-paystack-signature")) || ""
    body = conn.assigns[:raw_body] || ""

    case Payments.handle_webhook(body, signature) do
      :ok ->
        send_resp(conn, 200, "ok")

      {:ok, _} ->
        send_resp(conn, 200, "ok")

      {:error, :invalid_signature} ->
        send_resp(conn, 400, "invalid signature")

      {:error, _} ->
        send_resp(conn, 500, "error")
    end
  end

  def verify(conn, %{"reference" => reference}) do
    case Payments.confirm_payment(reference) do
      {:ok, _transaction} ->
        json(conn, %{message: "Payment confirmed"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: to_string(reason)})
    end
  end

  def deposit(conn, %{"amount" => amount}) do
    user = conn.assigns.current_user

    case Payments.create_deposit(user, amount) do
      {:ok, transaction} ->
        json(conn, %{
          access_code: transaction.paystack_access_code,
          reference: transaction.paystack_reference,
          amount: transaction.amount
        })

      {:error, reason} when is_binary(reason) ->
        conn |> put_status(:bad_request) |> json(%{error: reason})

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
        conn |> put_status(:unprocessable_entity) |> json(%{errors: errors})
    end
  end

  def withdraw(conn, %{"amount" => amount}) do
    user = conn.assigns.current_user

    case Payments.create_withdrawal(user, amount) do
      {:ok, transaction} ->
        json(conn, %{
          message: "Withdrawal successful",
          amount: transaction.amount,
          reference: transaction.paystack_reference
        })

      {:error, :no_phone_number} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "no_phone_number", message: "Please set your M-Pesa phone number before withdrawing."})

      {:error, {:rate_limited, remaining}} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{
          error: "rate_limited",
          message: "Withdrawal limit reached for this 10-minute window.",
          remaining_kes: remaining
        })

      {:error, :insufficient_balance} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Insufficient balance"})

      {:error, reason} when is_binary(reason) ->
        conn |> put_status(:bad_request) |> json(%{error: reason})

      {:error, _} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "Withdrawal failed"})
    end
  end

  def withdrawal_limit(conn, _params) do
    user = conn.assigns.current_user
    remaining = Payments.withdrawal_limit_remaining(user.id)
    json(conn, %{remaining_kes: remaining, window_minutes: 10})
  end

  def my_transactions(conn, _params) do
    user = conn.assigns.current_user
    transactions = Payments.list_transactions(user.id)
    json(conn, %{transactions: Enum.map(transactions, &transaction_json/1)})
  end

  defp transaction_json(t) do
    %{
      id: t.id,
      type: t.type,
      amount: t.amount,
      status: t.status,
      paystack_reference: t.paystack_reference,
      tournament_id: t.tournament_id,
      inserted_at: t.inserted_at
    }
  end
end
