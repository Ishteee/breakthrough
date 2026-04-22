package ws

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/coder/websocket"
)

func Handler(hub *Hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			InsecureSkipVerify: true,
		})
		if err != nil {
			log.Printf("ws accept: %v", err)
			return
		}

		client := &Client{
			conn: c,
			send: make(chan []byte, 16),
		}
		hub.register <- client

		go client.writePump()

		ctx := r.Context()
		for {
			_, data, err := c.Read(ctx)
			if err != nil {
				hub.unregister <- client
				return
			}
			msg, err := parseLocation(data)
			if err != nil {
				log.Printf("bad location: %v", err)
				continue
			}
			out, err := json.Marshal(msg)
			if err != nil {
				log.Printf("marshal: %v", err)
				continue
			}
			hub.broadcast <- out
		}
	}
}
