package main

import (
	"log"
	"net/http"

	"github.com/Ishteee/breakthrough/backend/greet"
	"github.com/Ishteee/breakthrough/backend/ws"
)

func main() {
	hub := ws.NewHub()
	go hub.Run()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", health)
	mux.HandleFunc("GET /hello", greet.Hello)
	mux.HandleFunc("GET /ws", ws.Handler(hub))

	addr := ":8080"
	log.Printf("listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func health(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}
