// Package handlers wires HTTP endpoints to the widget store.
package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/example/go_service/models"
	"github.com/example/go_service/store"
)

// API bundles the dependencies shared by all HTTP handlers.
type API struct {
	store store.Store
}

// NewAPI constructs an API backed by the given store.
func NewAPI(s store.Store) *API {
	return &API{store: s}
}

// Register attaches every widget route to the provided mux.
// Uses Go 1.22 method+path patterns registered on net/http.ServeMux.
func (a *API) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /widgets", a.ListWidgets)
	mux.HandleFunc("POST /widgets", a.CreateWidget)
	mux.HandleFunc("GET /widgets/{id}", a.GetWidget)
	mux.HandleFunc("DELETE /widgets/{id}", a.DeleteWidget)
	mux.HandleFunc("GET /stats", a.Stats)
	mux.HandleFunc("GET /health", a.Health)
}

// ListWidgets returns all widgets as JSON. GET /widgets
func (a *API) ListWidgets(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, a.store.List())
}

// CreateWidget decodes a widget from the request body and stores it. POST /widgets
func (a *API) CreateWidget(w http.ResponseWriter, r *http.Request) {
	var widget models.Widget
	if err := json.NewDecoder(r.Body).Decode(&widget); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if err := widget.Validate(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	id := a.store.Save(widget)
	writeJSON(w, http.StatusCreated, map[string]models.WidgetID{"id": id})
}

// GetWidget returns a single widget by id. GET /widgets/{id}
func (a *API) GetWidget(w http.ResponseWriter, r *http.Request) {
	id, err := parseID(r.PathValue("id"))
	if err != nil {
		http.Error(w, "bad id", http.StatusBadRequest)
		return
	}
	widget, err := a.store.Get(id)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	writeJSON(w, http.StatusOK, widget)
}

// DeleteWidget removes a widget by id. DELETE /widgets/{id}
func (a *API) DeleteWidget(w http.ResponseWriter, r *http.Request) {
	id, err := parseID(r.PathValue("id"))
	if err != nil {
		http.Error(w, "bad id", http.StatusBadRequest)
		return
	}
	if !a.store.Delete(id) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// Stats reports store metrics as JSON. GET /stats
func (a *API) Stats(w http.ResponseWriter, r *http.Request) {
	s := a.store.Stats()
	writeJSON(w, http.StatusOK, map[string]string{"summary": s.Summary()})
}

// Health is a simple liveness probe. GET /health
func (a *API) Health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// writeJSON is a shared unexported helper that serializes body as JSON.
func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

// parseID converts a path segment into a models.WidgetID.
func parseID(raw string) (models.WidgetID, error) {
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, err
	}
	return models.WidgetID(n), nil
}
