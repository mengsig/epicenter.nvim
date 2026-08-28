package store

// Single (non-grouped) import form, exercised in its own file.
import "fmt"

// Stats summarizes a store snapshot for reporting endpoints.
type Stats struct {
	Total int `json:"total"`
}

// IsEmpty reports whether the snapshot holds no widgets. Value receiver.
func (st Stats) IsEmpty() bool {
	return st.Total == 0
}

// Summary renders the stats as a short human-readable string. Value receiver.
func (st Stats) Summary() string {
	return fmt.Sprintf("%d widgets", st.Total)
}
