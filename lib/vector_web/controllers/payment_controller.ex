defmodule VectorWeb.PaymentController do
  use VectorWeb, :controller

  alias Vector.Payments

  def webhook(conn, _params) do
    signature = List.first(get_req_header(conn, "x-paystack-signature")) || ""
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    case Payments.handle_webhook(body, signature) do
      :ok ->
        send_resp(conn, 200, "ok")

      {:ok, _} ->
        send_resp(conn, 200, "ok")

      {:error, :invalid_signature} ->
        send_resp(conn, 400, "invalid signature")

      {:error, _} ->
        send_resp(conn, 200, "ok")
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
