package event

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

func AppendAudit(storeDir, evID string, hits []RedactHit) error {
	if len(hits) == 0 {
		return nil
	}
	dir := filepath.Join(storeDir, "audit")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	now := time.Now().UTC()
	path := filepath.Join(dir, "redactions-"+now.Format("2006-01")+".jsonl")
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	row := map[string]any{
		"ts":    now.Format(time.RFC3339Nano),
		"event": evID,
		"hits":  hits,
	}
	buf, err := json.Marshal(row)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(buf, '\n')); err != nil {
		return err
	}
	return f.Sync()
}
