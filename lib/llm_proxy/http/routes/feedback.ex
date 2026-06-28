defmodule LLMProxy.HTTP.Routes.Feedback do
  @moduledoc """
  Trace feedback endpoint for attaching user ratings and comments to request IDs or trace IDs.
  """
  use Plug.Router

  alias LLMProxy.HTTP.Routes.Helpers
  alias LLMProxy.Plugs.Auth
  alias LLMProxy.Storage

  plug(Auth)
  plug(:match)
  plug(:dispatch)

  post "/" do
    case feedback_attrs(conn.assigns.api_key, conn.body_params) do
      {:ok, attrs} ->
        case Storage.record_trace_feedback(attrs) do
          {:ok, feedback} ->
            Helpers.send_json(conn, 201, render_feedback(feedback))

          {:error, changeset} ->
            Helpers.send_json(conn, 400, %{error: "Invalid feedback", details: errors(changeset)})
        end

      {:error, reason} ->
        Helpers.send_json(conn, 400, %{error: reason})
    end
  end

  match _ do
    Helpers.send_json(conn, 404, %{error: "Not found"})
  end

  defp feedback_attrs(api_key, params) do
    with {:ok, request_id, trace_id} <- trace_ref(params),
         {:ok, rating} <- rating(params) do
      {:ok,
       %{
         key_id: api_key.id,
         request_id: request_id,
         trace_id: trace_id,
         rating: rating,
         comment: string_value(params["comment"]),
         metadata: map_value(params["metadata"])
       }
       |> Enum.reject(fn {_key, value} -> is_nil(value) end)
       |> Map.new()}
    end
  end

  defp trace_ref(%{"request_id" => request_id}) when is_binary(request_id) and request_id != "" do
    {:ok, request_id, nil}
  end

  defp trace_ref(%{"trace_id" => trace_id}) when is_integer(trace_id) do
    {:ok, Integer.to_string(trace_id), trace_id}
  end

  defp trace_ref(%{"trace_id" => trace_id}) when is_binary(trace_id) and trace_id != "" do
    case Integer.parse(trace_id) do
      {id, ""} -> {:ok, trace_id, id}
      _other -> {:ok, trace_id, nil}
    end
  end

  defp trace_ref(_params), do: {:error, "request_id or trace_id is required"}

  defp rating(%{"rating" => rating}) when rating in ["positive", "negative", "neutral"] do
    {:ok, rating}
  end

  defp rating(_params), do: {:error, "rating must be positive, negative, or neutral"}

  defp string_value(value) when is_binary(value) and value != "", do: value
  defp string_value(_value), do: nil

  defp map_value(value) when is_map(value), do: value
  defp map_value(_value), do: %{}

  defp render_feedback(feedback) do
    %{
      id: feedback.id,
      trace_id: feedback.trace_id,
      request_id: feedback.request_id,
      rating: feedback.rating,
      comment: feedback.comment,
      metadata: feedback.metadata,
      timestamp: feedback.timestamp
    }
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
