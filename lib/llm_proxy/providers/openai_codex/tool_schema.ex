defmodule LLMProxy.Providers.OpenAICodex.ToolSchema do
  @moduledoc false

  alias ReqLLM.Providers.OpenAI.AdapterHelpers

  defmodule FunctionTool do
    @moduledoc false
    @enforce_keys [:name, :parameters]
    defstruct [:name, :description, :parameters]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            parameters: map()
          }
  end

  @spec strictify([map()] | nil) :: [map()] | nil
  def strictify(nil), do: nil
  def strictify(tools) when is_list(tools), do: Enum.map(tools, &strictify_tool/1)

  defp strictify_tool(%{"type" => "function", "function" => function} = tool)
       when is_map(function) do
    function
    |> function_tool!()
    |> to_wrapped_openai_tool(tool)
  end

  defp strictify_tool(
         %{"type" => "function", "name" => _name, "parameters" => _parameters} = tool
       ) do
    tool
    |> function_tool!()
    |> to_flat_openai_tool(tool)
  end

  defp strictify_tool(tool), do: tool

  defp function_tool!(%{"name" => name, "parameters" => parameters} = function)
       when is_binary(name) and is_map(parameters) do
    %FunctionTool{
      name: name,
      description: function["description"],
      parameters: AdapterHelpers.enforce_strict_recursive(parameters)
    }
  end

  defp function_tool!(function) do
    raise ArgumentError, "invalid OpenAI function tool: #{inspect(function)}"
  end

  defp to_wrapped_openai_tool(%FunctionTool{} = function, original_tool) do
    function_map = %{
      "name" => function.name,
      "parameters" => function.parameters
    }

    function_map =
      if is_binary(function.description),
        do: Map.put(function_map, "description", function.description),
        else: function_map

    %{original_tool | "function" => function_map}
  end

  defp to_flat_openai_tool(%FunctionTool{} = function, original_tool) do
    original_tool
    |> Map.put("name", function.name)
    |> Map.put("parameters", function.parameters)
    |> maybe_put_description(function.description)
  end

  defp maybe_put_description(tool, description) when is_binary(description),
    do: Map.put(tool, "description", description)

  defp maybe_put_description(tool, _description), do: tool
end
