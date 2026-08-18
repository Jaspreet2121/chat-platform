defmodule UserService.UpiTest do
  @moduledoc """
  The UPI payload contract (100): parsing (identity out, EVERYTHING else passed through), the
  canonical payload string LOCKED byte-for-byte (changing it silently would change every regenerated
  QR), and the PNG renderer's envelope (512×512, deterministic).
  """
  use ExUnit.Case, async: true

  alias UserService.{Upi, UpiQr}

  @scanned "upi://pay?pa=shop.owner-1@okaxis&pn=Sharma%20Stores&mc=5411&tr=INV42&tn=Groceries&sign=aBc%2F%2Bx&cu=INR"

  test "parse: identity extracted, every merchant param passed through, cu dropped (canonical owns it)" do
    assert {:ok, parsed} = Upi.parse_payload(@scanned)
    assert parsed.upi_id == "shop.owner-1@okaxis"
    assert parsed.payment_name == "Sharma Stores"

    # PASSTHROUGH LOCKED: mc/tr/tn/sign survive verbatim (sign already url-decoded by the parse);
    # pa/pn/cu never leak into the merchant map.
    assert parsed.merchant == %{
             "mc" => "5411",
             "tr" => "INV42",
             "tn" => "Groceries",
             "sign" => "aBc/+x"
           }
  end

  test "parse: scheme is case-insensitive; junk schemes and missing/invalid pa are typed errors" do
    assert {:ok, _} = Upi.parse_payload("UPI://PAY?pa=a.b@bank")
    assert {:error, :invalid_scheme} = Upi.parse_payload("https://evil.example?pa=a.b@bank")
    assert {:error, :invalid_scheme} = Upi.parse_payload("upi://collect?pa=a.b@bank")
    assert {:error, :invalid_scheme} = Upi.parse_payload("not a url")
    assert {:error, :missing_pa} = Upi.parse_payload("upi://pay?pn=NoVpa")
    assert {:error, :invalid_vpa} = Upi.parse_payload("upi://pay?pa=has%20space@bank")
    assert {:error, :invalid_vpa} = Upi.parse_payload("upi://pay?pa=x@123")
  end

  test "parse: pn is truncated to 100; validate_vpa enforces the pattern" do
    long = String.duplicate("n", 150)
    assert {:ok, parsed} = Upi.parse_payload("upi://pay?pa=a.b@bank&pn=#{long}")
    assert String.length(parsed.payment_name) == 100

    assert {:ok, "merchant_x-1@icici"} = Upi.validate_vpa("merchant_x-1@icici")
    assert {:error, :invalid_vpa} = Upi.validate_vpa("@bank")
    assert {:error, :invalid_vpa} = Upi.validate_vpa("a@")
  end

  test "THE CANONICAL PAYLOAD IS LOCKED: pa, pn, cu=INR, then merchant params sorted by key" do
    {:ok, parsed} = Upi.parse_payload(@scanned)

    assert Upi.canonical_payload(parsed.upi_id, parsed.payment_name, parsed.merchant) ==
             "upi://pay?pa=shop.owner-1%40okaxis&pn=Sharma%20Stores&cu=INR" <>
               "&mc=5411&sign=aBc%2F%2Bx&tn=Groceries&tr=INV42"
  end

  test "round-trip: canonical payload re-parses to the SAME identity + merchant map" do
    {:ok, parsed} = Upi.parse_payload(@scanned)
    canonical = Upi.canonical_payload(parsed.upi_id, parsed.payment_name, parsed.merchant)

    assert {:ok, reparsed} = Upi.parse_payload(canonical)
    assert reparsed.upi_id == parsed.upi_id
    assert reparsed.payment_name == parsed.payment_name
    assert reparsed.merchant == parsed.merchant
  end

  test "no payment_name → pn omitted entirely (never an empty pn=)" do
    assert Upi.canonical_payload("a.b@bank", nil, %{}) == "upi://pay?pa=a.b%40bank&cu=INR"
  end

  test "render_png: a 512×512 grayscale PNG, deterministic for the same payload" do
    {:ok, png} = UpiQr.render_png("upi://pay?pa=a.b@bank&cu=INR")

    assert <<137, ?P, ?N, ?G, 13, 10, 26, 10, _len::32, "IHDR", width::32, height::32,
             _rest::binary>> = png

    assert width == 512
    assert height == 512

    {:ok, png2} = UpiQr.render_png("upi://pay?pa=a.b@bank&cu=INR")
    assert png == png2

    {:ok, other} = UpiQr.render_png("upi://pay?pa=other@bank&cu=INR")
    refute png == other
  end
end
