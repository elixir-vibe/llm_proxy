defmodule LLMProxy.Admin.Resources.Message do
  @moduledoc "Admin resource for logged user messages."

  use Incant.Resource,
    schema: LLMProxy.Schemas.MessageLog,
    title: "Messages"

  table density: :compact do
    column(:timestamp, link: true, format: :datetime)
    column(:key_id)
    column(:model)
    column(:route)
    column(:user_message, label: "Message")

    filter(:model, :text)
    filter(:route, :text)
    filter(:timestamp, :date_range)

    row_detail(:message, label: "Message")
  end

  def index(params, _context), do: LLMProxy.Storage.get_messages(params)
end
