// Package client is a thin HTTP client for the widget service.
package client

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/example/go_service/models"
)

// Client talks to a running widget service over HTTP.
type Client struct {
	BaseURL string
	http    *http.Client
}

// NewClient builds a Client pointing at baseURL.
func NewClient(baseURL string) *Client {
	return &Client{BaseURL: baseURL, http: http.DefaultClient}
}

// FetchAll retrieves every widget. It hits GET /widgets.
func (c *Client) FetchAll() ([]models.Widget, error) {
	resp, err := c.http.Get(c.BaseURL + "/widgets")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out []models.Widget
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return out, nil
}

// Create posts a new widget. It hits POST /widgets.
func (c *Client) Create(w models.Widget) error {
	body, err := json.Marshal(w)
	if err != nil {
		return err
	}
	resp, err := c.http.Post(c.BaseURL+"/widgets", "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		return fmt.Errorf("create failed: %d", resp.StatusCode)
	}
	return nil
}
