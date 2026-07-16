defmodule LLMProxy.Admin.Resources.Message do
  @moduledoc "Admin resource for logged user messages."

  use Incant.Resource,
    schema: LLMProxy.Schemas.MessageLog,
    repo: LLMProxy.Storage.Repo,
    title: "Messages"

  table density: :compact, default_sort: [timestamp: :desc] do
    column(:timestamp, link: true, format: :datetime, priority: :primary)
    column(:key_id, format: :id, priority: :tertiary)
    column(:model, priority: :primary)
    column(:route, priority: :secondary)
    column(:user_message, label: "Message", sensitive: true, priority: :secondary)

    filter(:model, :combobox, options: :distinct)
    filter(:route, :select, options: :distinct)
    filter(:timestamp, :date_range)

    row_detail(:message, label: "Message")

    search([:model, :route, :user_message])
  end
end
