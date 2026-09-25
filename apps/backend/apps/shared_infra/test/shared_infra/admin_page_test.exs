defmodule SharedInfra.AdminPageTest do
  @moduledoc """
  The one page parser every admin list uses, as pure logic.

  Two properties carry it. The page size is the SERVER'S — a caller may pick from the selector and
  can never go above the ceiling, which is the only thing separating a list over personal data from
  an export endpoint. And the envelope is arithmetic the UI trusts blindly: "Page N of M" is rendered
  straight from `total_pages`, so an off-by-one here is a Next button onto an empty page.
  """
  use ExUnit.Case, async: true

  alias SharedInfra.AdminPage

  describe "parse/1" do
    test "absent or junk lands on page 1 at the default size" do
      for params <- [%{}, %{"page" => "x", "page_size" => "y"}, %{"page" => 0, "page_size" => -5}] do
        assert AdminPage.parse(params) == %{page: 1, page_size: 50, offset: 0}
      end
    end

    test "page and size are read as strings or integers, and the offset follows" do
      assert AdminPage.parse(%{"page" => "3", "page_size" => "20"}) == %{
               page: 3,
               page_size: 20,
               offset: 40
             }

      assert AdminPage.parse(%{"page" => 2, "page_size" => 10}).offset == 10
    end

    test "a caller can NEVER widen the page past the ceiling" do
      assert AdminPage.parse(%{"page_size" => 5_000}).page_size == 100
      assert AdminPage.parse(%{"page_size" => "5000"}).page_size == 100
      assert AdminPage.parse(%{"page_size" => 100}).page_size == 100
    end
  end

  describe "envelope/2" do
    test "counts pages by rounding UP, and never reports zero pages" do
      assert AdminPage.envelope(%{page: 1, page_size: 50}, 0).total_pages == 1
      assert AdminPage.envelope(%{page: 1, page_size: 50}, 50).total_pages == 1
      assert AdminPage.envelope(%{page: 1, page_size: 50}, 51).total_pages == 2
      assert AdminPage.envelope(%{page: 4, page_size: 20}, 587).total_pages == 30
    end

    test "carries the page, size and total through unchanged" do
      assert AdminPage.envelope(%{page: 4, page_size: 20}, 587) == %{
               page: 4,
               page_size: 20,
               total: 587,
               total_pages: 30
             }
    end
  end

  test "the order is newest-first with the id as tiebreak, and the window is LIMIT/OFFSET" do
    assert AdminPage.order("t", "i") == "ORDER BY t DESC, i DESC"
    assert AdminPage.window(%{page_size: 20, offset: 40}) == "LIMIT 20 OFFSET 40"
  end
end
