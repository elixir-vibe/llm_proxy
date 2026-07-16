defmodule LLMProxy.Admin.Resources.Message do
  @moduledoc "Admin resource for logged user messages."

  use Incant.Resource,
    schema: LLMProxy.Schemas.MessageLog,
    title: "Messages"

  table density: :compact do
    column(:timestamp, link: true, format: :datetime, priority: :primary)
    column(:key_id, format: :id, priority: :tertiary)
    column(:model, priority: :primary)
    column(:route, priority: :secondary)
    column(:user_message, label: "Message", sensitive: true, priority: :secondary)

    filter(:model, :text)
    filter(:route, :text)
    filter(:timestamp, :date_range)

    row_detail(:message, label: "Message")
  end

  def index(params, _context), do: LLMProxy.Storage.get_messages(params)
end
