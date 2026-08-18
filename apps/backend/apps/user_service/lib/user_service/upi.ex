defmodule UserService.Upi do
  @moduledoc """
  UPI deep-link parsing + canonicalization (100). The client scans ANY UPI QR (merchant sticker,
  bank, PSP app) and sends the raw `upi://pay?...` string; this module extracts the identity
  (`pa` → upi_id, `pn` → payment_name) and passes every OTHER param through UNTOUCHED as the
  merchant map (mc, tr, tn, mode, purpose, orgid, sign, ...), so the QR we regenerate is
  functionally identical to the one scanned — we never invent and never drop merchant params.

  `canonical_payload/3` is the single, DETERMINISTIC payload the server-side QR PNG is rendered
  from: `upi://pay?pa=..&pn=..&cu=INR` + the merchant params sorted by key. Its exact string is
  locked by tests — changing it silently would change every regenerated QR.
  """

  @vpa_pattern ~r/^[a-zA-Z0-9.\-_]{2,256}@[a-zA-Z]{2,64}$/
  @payment_name_max 100

  @doc """
  Parse a scanned `upi://pay?...` payload. → `{:ok, %{upi_id, payment_name (nil when absent),
  merchant}}` | `{:error, :invalid_scheme | :missing_pa | :invalid_vpa}`.
  """
  def parse_payload(payload) when is_binary(payload) do
    with {:ok, query} <- split_scheme(payload),
         params = URI.decode_query(query),
         {:ok, upi_id} <- fetch_vpa(params) do
      payment_name =
        case Map.get(params, "pn") do
          name when is_binary(name) and name != "" -> String.slice(name, 0, @payment_name_max)
          _ -> nil
        end

      # Everything that is not identity (pa/pn) or currency (canonical forces cu=INR) passes
      # through verbatim — dropping a merchant's tr/mc/sign would break their reconciliation.
      merchant = Map.drop(params, ["pa", "pn", "cu"])

      {:ok, %{upi_id: upi_id, payment_name: payment_name, merchant: merchant}}
    end
  end

  def parse_payload(_payload), do: {:error, :invalid_scheme}

  @doc "Validate a manually-entered VPA. → {:ok, vpa} | {:error, :invalid_vpa}."
  def validate_vpa(vpa) when is_binary(vpa) do
    if Regex.match?(@vpa_pattern, vpa), do: {:ok, vpa}, else: {:error, :invalid_vpa}
  end

  def validate_vpa(_), do: {:error, :invalid_vpa}

  @doc """
  The deterministic payload the QR PNG renders: pa, pn (when set), cu=INR, then every merchant
  param sorted by key. Values are percent-encoded (%20 form, never '+': PSP parsers are strict).
  """
  def canonical_payload(upi_id, payment_name, merchant) when is_map(merchant) do
    lead =
      [{"pa", upi_id}] ++
        if(is_binary(payment_name) and payment_name != "",
          do: [{"pn", payment_name}],
          else: []
        ) ++ [{"cu", "INR"}]

    passthrough = merchant |> Enum.sort_by(fn {key, _} -> key end)

    query =
      (lead ++ passthrough)
      |> Enum.map_join("&", fn {key, value} -> key <> "=" <> encode(to_string(value)) end)

    "upi://pay?" <> query
  end

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # Scheme match is case-insensitive ("UPI://PAY?..." scans exist in the wild); anything that is
  # not upi://pay is refused — we never store an arbitrary deep link.
  defp split_scheme(payload) do
    case String.split(payload, "?", parts: 2) do
      [scheme, query] ->
        if String.downcase(String.trim(scheme)) == "upi://pay",
          do: {:ok, query},
          else: {:error, :invalid_scheme}

      _ ->
        {:error, :invalid_scheme}
    end
  end

  defp fetch_vpa(params) do
    case Map.get(params, "pa") do
      pa when is_binary(pa) and pa != "" ->
        if Regex.match?(@vpa_pattern, pa), do: {:ok, pa}, else: {:error, :invalid_vpa}

      _ ->
        {:error, :missing_pa}
    end
  end
end
