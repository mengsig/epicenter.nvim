// Command go_service runs the widget HTTP API.
package main

import (
	"log"
	"net/http"

	"github.com/example/go_service/handlers"
	"github.com/example/go_service/store"
)

// defaultAddr is the listen address when none is configured.
const defaultAddr = ":8080"

func main() {
	st := store.NewMemoryStore()
	api := handlers.NewAPI(st)

	mux := http.NewServeMux()
	api.Register(mux)

	log.Printf("widget service listening on %s", defaultAddr)
	if err := http.ListenAndServe(defaultAddr, mux); err != nil {
		log.Fatal(err)
	}
}
