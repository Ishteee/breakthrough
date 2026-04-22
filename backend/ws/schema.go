package ws

import (
	"encoding/json"
	"errors"
	"time"
)

type LocationMessage struct {
	UserID    string  `json:"userID"`
	Lat       float64 `json:"lat"`
	Lng       float64 `json:"lng"`
	Timestamp int64   `json:"timestamp"`
}

func parseLocation(data []byte) (LocationMessage, error) {
	var m LocationMessage
	if err := json.Unmarshal(data, &m); err != nil {
		return m, err
	}
	if m.UserID == "" {
		return m, errors.New("userID required")
	}
	if m.Lat < -90 || m.Lat > 90 {
		return m, errors.New("lat out of range")
	}
	if m.Lng < -180 || m.Lng > 180 {
		return m, errors.New("lng out of range")
	}
	m.Timestamp = time.Now().UnixMilli()
	return m, nil
}