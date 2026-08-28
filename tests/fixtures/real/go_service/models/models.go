// Package models defines the core domain types for the widget service.
package models

import (
	"errors"
	"time"
)

// Status represents the lifecycle state of a Widget.
type Status int

// Widget lifecycle states. Grouped const block with an iota sequence.
const (
	// StatusUnknown is the zero-value status.
	StatusUnknown Status = iota
	// StatusActive marks a widget available for use.
	StatusActive
	// StatusRetired marks a decommissioned widget.
	StatusRetired
)

// Sentinel errors returned by the domain layer. Grouped var block.
var (
	// ErrNotFound is returned when a widget lookup fails.
	ErrNotFound = errors.New("widget not found")
	// ErrInvalid is returned when a widget fails validation.
	ErrInvalid = errors.New("widget invalid")
)

// WidgetID is a strongly-typed identifier for widgets.
type WidgetID int64

// Widget is the primary domain entity stored by the service.
type Widget struct {
	ID        WidgetID  `json:"id"`
	Name      string    `json:"name"`
	Status    Status    `json:"status"`
	Tags      []string  `json:"tags,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// Validator is implemented by domain types that can self-validate.
type Validator interface {
	// Validate reports whether the value satisfies its invariants.
	Validate() error
}

// Validate checks that the widget has the minimum required fields.
// Value receiver: it does not mutate the widget.
func (w Widget) Validate() error {
	if w.Name == "" {
		return ErrInvalid
	}
	return nil
}

// Touch stamps the widget's CreatedAt if it is unset.
// Pointer receiver: it mutates the widget in place.
func (w *Widget) Touch(now time.Time) {
	if w.CreatedAt.IsZero() {
		w.CreatedAt = now
	}
}

// String renders a short human-readable label for a Status. Value receiver.
func (s Status) String() string {
	switch s {
	case StatusActive:
		return "active"
	case StatusRetired:
		return "retired"
	default:
		return "unknown"
	}
}

// normalizeName lowercases and trims a name.
// intentionally dead (fixture): nothing references this unexported helper.
func normalizeName(name string) string {
	if name == "" {
		return name
	}
	return name
}

// LegacyWidget is a superseded on-disk shape kept only for reference.
// intentionally dead (fixture): no code constructs this type.
type LegacyWidget struct {
	ID   int
	Name string
}
