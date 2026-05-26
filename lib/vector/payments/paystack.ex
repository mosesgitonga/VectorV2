defmodule Vector.Payments.Paystack do
  @moduledoc "Paystack API client."

  @base_url "https://api.paystack.co"

  def initialize_transaction(email, amount_kobo, reference, metadata \\ %{}) do
    body = %{
      email: email,
      amount: amount_kobo,
      reference: reference,
      metadata: metadata
    }

    post("/transaction/initialize", body)
  end

  def verify_transaction(reference) do
    get("/transaction/verify/#{reference}")
  end

  def refund(reference, amount_kobo) do
    body = %{transaction: reference, amount: amount_kobo}
    post("/refund", body)
  end

  def transfer_recipient(name, account_number, bank_code) do
    body = %{
      type: "nuban",
      name: name,
      account_number: account_number,
      bank_code: bank_code,
      currency: "KES"
    }

    post("/transferrecipient", body)
  end

  def initiate_transfer(amount_kobo, recipient_code, reason) do
    body = %{
      source: "balance",
      amount: amount_kobo,
      recipient: recipient_code,
      reason: reason
    }

    post("/transfer", body)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp post(path, body) do
    url = @base_url <> path
    headers = build_headers()
    encoded = Jason.encode!(body)

    case Finch.build(:post, url, headers, encoded) |> Finch.request(Vector.Finch) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.decode!(body)}

      {:ok, %{body: body}} ->
        {:error, Jason.decode!(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get(path) do
    url = @base_url <> path
    headers = build_headers()

    case Finch.build(:get, url, headers) |> Finch.request(Vector.Finch) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.decode!(body)}

      {:ok, %{body: body}} ->
        {:error, Jason.decode!(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_headers do
    secret = Application.fetch_env!(:vector, :paystack_secret_key)
    [
      {"Authorization", "Bearer #{secret}"},
      {"Content-Type", "application/json"}
    ]
  end

end
