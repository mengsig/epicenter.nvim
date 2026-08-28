// Package store provides an in-memory persistence layer for widgets.
package store

import (
	"sync"
	"time"

	"github.com/example/go_service/models"
)

// Store is the persistence interface the HTTP layer depends on.
type Store interface {
	// Get returns a single widget or models.ErrNotFound.
	Get(id models.WidgetID) (models.Widget, error)
	// List returns every stored widget.
	List() []models.Widget
	// Save inserts or updates a widget and returns its id.
	Save(w models.Widget) models.WidgetID
	// Delete removes a widget, reporting whether it existed.
	Delete(id models.WidgetID) bool
	// Stats returns a snapshot summary of the store.
	Stats() Stats
}

// MemoryStore is a thread-safe in-memory implementation of Store.
type MemoryStore struct {
	mu     sync.RWMutex
	items  map[models.WidgetID]models.Widget
	nextID models.WidgetID
}

// NewMemoryStore constructs an empty MemoryStore.
func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		items:  make(map[models.WidgetID]models.Widget),
		nextID: 1,
	}
}

// Get returns the widget with the given id or models.ErrNotFound.
// Pointer receiver: MemoryStore carries a mutex and must not be copied.
func (s *MemoryStore) Get(id models.WidgetID) (models.Widget, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	w, ok := s.items[id]
	if !ok {
		return models.Widget{}, models.ErrNotFound
	}
	return w, nil
}

// List returns all stored widgets in arbitrary order. Pointer receiver.
func (s *MemoryStore) List() []models.Widget {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]models.Widget, 0, len(s.items))
	for _, w := range s.items {
		out = append(out, w)
	}
	return out
}

// Save inserts or updates a widget, assigning an id when one is missing.
// It stamps the creation time via the models.Widget pointer method.
func (s *MemoryStore) Save(w models.Widget) models.WidgetID {
	s.mu.Lock()
	defer s.mu.Unlock()
	if w.ID == 0 {
		w.ID = s.nextID
		s.nextID++
	}
	w.Touch(time.Now())
	s.items[w.ID] = w
	return w.ID
}

// Delete removes a widget, reporting whether it existed. Pointer receiver.
func (s *MemoryStore) Delete(id models.WidgetID) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.items[id]; !ok {
		return false
	}
	delete(s.items, id)
	return true
}

// Stats computes a snapshot summary while holding the read lock.
func (s *MemoryStore) Stats() Stats {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return Stats{Total: len(s.items)}
}
