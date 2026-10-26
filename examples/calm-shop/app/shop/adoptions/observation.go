// Optional test observations use standard OTLP/HTTP JSON. Each export is
// synchronous, so this example has no SDK queue to drain. Production applications
// can use their existing OpenTelemetry SDK and report its ForceFlush outcome.
package adoptions

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

var observationState struct {
	sync.Mutex
	intended uint64
	dropped  uint64
}

func observeOperation(operation, edge string) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" || os.Getenv("IRONFRAME_OBSERVATION_CONFIG") == "" {
		return
	}
	observationState.Lock()
	defer observationState.Unlock()
	observationState.intended++
	persistObservationCount("intended")
	attributes := []map[string]any{}
	for _, field := range strings.Split(os.Getenv("OTEL_RESOURCE_ATTRIBUTES"), ",") {
		if key, value, ok := strings.Cut(field, "="); ok {
			attributes = append(attributes, map[string]any{"key": key, "value": map[string]any{"stringValue": value}})
		}
	}
	record := map[string]any{
		"body":       map[string]any{"stringValue": operation + " invocation ended"},
		"attributes": []map[string]any{{"key": "ironframe.edge.id", "value": map[string]any{"stringValue": edge}}},
	}
	payload := map[string]any{"resourceLogs": []map[string]any{{
		"resource":  map[string]any{"attributes": attributes},
		"scopeLogs": []map[string]any{{"logRecords": []map[string]any{record}}},
	}}}
	if err := observationPost(endpoint+"/v1/logs", payload); err != nil {
		observationState.dropped++
		persistObservationCount("dropped")
		fmt.Fprintln(os.Stderr, "observation export:", err)
	}
}

func observationPost(endpoint string, value any) error {
	body, err := json.Marshal(value)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 5 * time.Second}
	response, err := client.Post(endpoint, "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		return fmt.Errorf("receiver answered %s", response.Status)
	}
	var result struct {
		PartialSuccess *struct{} `json:"partialSuccess"`
	}
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		return err
	}
	if result.PartialSuccess != nil {
		return fmt.Errorf("receiver reported partial success")
	}
	return nil
}

// Accounting precedes export, so the parent runner can detect losses after the
// native process exits without replacing LawSpec's generated TestMain.
func persistObservationCount(kind string) {
	path := os.Getenv("IRONFRAME_OBSERVATION_COUNTS_FILE")
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0600)
	if err != nil {
		panic(fmt.Sprintf("observation accounting: %v", err))
	}
	_, writeError := fmt.Fprintf(file, "{\"kind\":%q}\n", kind)
	syncError := file.Sync()
	closeError := file.Close()
	if writeError != nil || syncError != nil || closeError != nil {
		panic(fmt.Sprintf("observation accounting: %v %v %v", writeError, syncError, closeError))
	}
}
