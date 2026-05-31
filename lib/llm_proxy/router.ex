defmodule LLMProxy.Router do
  @moduledoc """
  Public router facade for embedding LLMProxy.

  Use this module as a Plug, or `use LLMProxy.Router` inside a Phoenix router.
  Concrete HTTP routing lives in `LLMProxy.HTTP.Router`; Phoenix forward macros
  live in `LLMProxy.Phoenix.Router`.
  """

  def init(opts), do: LLMProxy.HTTP.Router.init(opts)
  def call(conn, opts), do: LLMProxy.HTTP.Router.call(conn, opts)

  defmacro __using__(opts \\ []) do
    quote do
      use LLMProxy.Phoenix.Router, unquote(opts)
    end
  end

  defmacro llm_proxy_routes(opts \\ []) do
    opts = Macro.expand(opts, __CALLER__)
    path = Keyword.get(opts, :mount, "/")

    LLMProxy.Phoenix.Router.__routes_ast__(path, opts)
  end

  defmacro llm_proxy(path, opts \\ []) do
    LLMProxy.Phoenix.Router.__routes_ast__(
      Macro.expand(path, __CALLER__),
      Macro.expand(opts, __CALLER__)
    )
  end

  def __routes_ast__(path, opts), do: LLMProxy.Phoenix.Router.__routes_ast__(path, opts)
end
