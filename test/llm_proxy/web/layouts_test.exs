defmodule LLMProxy.Web.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias LLMProxy.Web.Layouts

  test "renders the root layout" do
    html = render_component(&Layouts.root/1, %{inner_content: "Hello"})

    assert html =~ "LLM Proxy Admin"
    assert html =~ "Hello"
    assert html =~ "/assets/css/app"
    assert html =~ "/assets/js/app"
  end
end
