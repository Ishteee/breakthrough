package ws

import (
	"context"
	"log"
	"time"

	"github.com/coder/websocket"
)

type Client struct {
	conn *websocket.Conn
	send chan []byte
}

type Hub struct {
	clients    map[*Client]bool
	register   chan *Client
	unregister chan *Client
	broadcast  chan []byte
}

func NewHub() *Hub {
	return &Hub{
		clients:    make(map[*Client]bool),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		broadcast:  make(chan []byte),
	}
}

func (h *Hub) Run() {
	for {
		select {
		case c := <-h.register:
			h.clients[c] = true
			log.Printf("client registered (total=%d)", len(h.clients))

		case c := <-h.unregister:
			if _, ok := h.clients[c]; ok {
				delete(h.clients, c)
				close(c.send)
				log.Printf("client unregistered (total=%d)", len(h.clients))
			}

		case msg := <-h.broadcast:
			for c := range h.clients {
				select {
				case c.send <- msg:
				default:
					delete(h.clients, c)
					close(c.send)
				}
			}
		}
	}
}

func (c *Client) writePump() {
	defer c.conn.CloseNow()
	for msg := range c.send {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err := c.conn.Write(ctx, websocket.MessageText, msg)
		cancel()
		if err != nil {
			return
		}
	}
}
