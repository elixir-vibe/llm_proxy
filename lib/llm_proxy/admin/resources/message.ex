defmodule LLMProxy.Admin.Resources.Message do
  @moduledoc "Admin resource for logged user messages."

  alias LLMProxy.Admin.Query

  use Incant.Resource,
    schema: LLMProxy.Schemas.MessageLog,
    title: "Messages"

  table density: :compact do
    column(:timestamp, link: true, format: :datetime, priority: :primary)
    column(:key_id, format: :id, priority: :tertiary)
    column(:model, priority: :primary)
    column(:route, priority: :secondary)
    column(:user_message, label: "Message", sensitive: true, priority: :secondary)

    filter(:model, :combobox, options_from: :model)
    filter(:route, :select, options_from: :route)
    filter(:timestamp, :date_range)

    row_detail(:message, label: "Message")

    search([:model, :route, :user_message])
  end

  def index(params, _context) do
    params
    |> Query.options()
    |> LLMProxy.Storage.page_messages()
    |> Query.result()
  end
end
