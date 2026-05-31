import { Socket } from 'phoenix'
import { LiveSocket } from 'phoenix_live_view'

const csrfToken = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content
const liveSocket = new LiveSocket('/live', Socket, {
  params: { _csrf_token: csrfToken },
})

liveSocket.connect()

if (import.meta.hot) {
  import.meta.hot.accept()
}
