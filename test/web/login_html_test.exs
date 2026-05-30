defmodule LLMProxy.Web.LoginHTMLTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias LLMProxy.Web.LoginHTML

  test "renders login form without errors" do
    html = render_component(&LoginHTML.index/1, %{error: nil})

    assert html =~ "LLM Proxy Admin"
    assert html =~ "Master key"
    assert html =~ "Sign in"
  end

  test "renders validation errors" do
    html = render_component(&LoginHTML.index/1, %{error: "Invalid master key"})

    assert html =~ "Invalid master key"
  end
end
