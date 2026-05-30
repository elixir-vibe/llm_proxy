defmodule LLMProxy.Web.ErrorHTMLTest do
  use ExUnit.Case, async: true

  alias LLMProxy.Web.ErrorHTML

  test "renders status messages from templates" do
    assert ErrorHTML.render("404.html", %{}) == "Not Found"
    assert ErrorHTML.render("500.html", %{}) == "Internal Server Error"
  end
end
