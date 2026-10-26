// User-owned LawSpec adapter: the production handlers of the shop's two dependency abilities.
//
// The shop knows nothing of Ironframe, CALM or LawTwin. It reads its two settings the way many
// applications do, from its environment or else from a .env file in its working directory or one
// of its parents: KAFKA_BOOTSTRAP_SERVERS for the adoptions log and PETSTORE_URL for the pet
// registry. Whether either is the real service or a twin is decided by the architecture's bindings,
// never here, and the laws in spec/shop.lawspec do not change with it.
package adoptions

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kgo"
)

// The topic adoptions are published on.
const topic = "adoptions"

// setting reads a setting from the environment, else from the nearest .env file.
func setting(name string) string {
	if value, ok := os.LookupEnv(name); ok && value != "" {
		return value
	}
	dir, _ := os.Getwd()
	for range 4 {
		if value, ok := dotenv(filepath.Join(dir, ".env"), name); ok {
			return value
		}
		dir = filepath.Dir(dir)
	}
	panic(fmt.Sprintf("the setting %s is neither in the environment nor in a .env file", name))
}

func dotenv(path, name string) (string, bool) {
	file, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if ok && strings.TrimSpace(key) == name {
			return strings.Trim(strings.TrimSpace(value), `"`), true
		}
	}
	return "", false
}

// nextPet hands out pet ids: the shop chooses the id of each pet it registers, as the Petstore lets
// a client do. SHOP_PET_ID_BASE fixes the first, so a run against a seeded twin replays exactly.
var nextPet atomic.Int64

func init() {
	base := time.Now().UnixMilli() % 1_000_000_000 * 1000
	if text := os.Getenv("SHOP_PET_ID_BASE"); text != "" {
		if parsed, err := strconv.ParseInt(text, 10, 64); err == nil {
			base = parsed
		}
	}
	nextPet.Store(base)
}

// PetsHandler is the native handler of Pets: register, nameOf, over the Petstore API.
type PetsHandler struct {
	base   string
	client *http.Client
}

// NewPetsHandler makes the native handler the generated tests use.
func NewPetsHandler() Pets {
	return &PetsHandler{base: strings.TrimRight(setting("PETSTORE_URL"), "/"), client: &http.Client{Timeout: 10 * time.Second}}
}

type pet struct {
	ID        int64    `json:"id"`
	Name      string   `json:"name"`
	PhotoUrls []string `json:"photoUrls"`
	Status    string   `json:"status,omitempty"`
}

func (handler *PetsHandler) Register(value0 string) int64 {
	defer observeOperation("register", "service-registers-pets")
	body, _ := json.Marshal(pet{ID: nextPet.Add(1), Name: value0, PhotoUrls: []string{}, Status: "available"})
	response, err := handler.client.Post(handler.base+"/pet", "application/json", bytes.NewReader(body))
	if err != nil {
		panic(fmt.Sprintf("register %q: %v", value0, err))
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		panic(fmt.Sprintf("register %q: the Petstore answered %s", value0, response.Status))
	}
	var created pet
	if err := json.NewDecoder(response.Body).Decode(&created); err != nil {
		panic(fmt.Sprintf("register %q: %v", value0, err))
	}
	return created.ID
}

func (handler *PetsHandler) NameOf(value0 int64) LawSpecMaybe[string] {
	defer observeOperation("nameOf", "service-registers-pets")
	response, err := handler.client.Get(handler.base + "/pet/" + strconv.FormatInt(value0, 10))
	if err != nil {
		panic(fmt.Sprintf("nameOf %d: %v", value0, err))
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotFound {
		return LawSpecAbsent[string]()
	}
	if response.StatusCode/100 != 2 {
		panic(fmt.Sprintf("nameOf %d: the Petstore answered %s", value0, response.Status))
	}
	var found pet
	if err := json.NewDecoder(response.Body).Decode(&found); err != nil {
		panic(fmt.Sprintf("nameOf %d: %v", value0, err))
	}
	return LawSpecPresent(found.Name)
}

// The Kafka client is shared by every handler in the process, made on first use, and the topic is
// created once if it is not there.
var (
	kafkaOnce   sync.Once
	kafkaClient *kgo.Client
	kafkaErr    error
	// Where each pet's adoption was written, so a lookup reads it back from that offset.
	written sync.Map
)

func kafka() *kgo.Client {
	kafkaOnce.Do(func() {
		seeds := strings.Split(setting("KAFKA_BOOTSTRAP_SERVERS"), ",")
		kafkaClient, kafkaErr = kgo.NewClient(
			kgo.SeedBrokers(seeds...),
			kgo.ClientID("calm-shop"),
			kgo.RetryTimeout(5*time.Second),
			kgo.RecordPartitioner(kgo.ManualPartitioner()),
			kgo.ProducerLinger(0),
		)
		if kafkaErr != nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		created, err := kadm.NewClient(kafkaClient).CreateTopics(ctx, 1, 1, nil, topic)
		if err != nil {
			kafkaErr = err
			return
		}
		if result, ok := created[topic]; ok && result.Err != nil && !strings.Contains(result.Err.Error(), "TOPIC_ALREADY_EXISTS") {
			kafkaErr = result.Err
		}
	})
	if kafkaErr != nil {
		panic(fmt.Sprintf("kafka at %s: %v", setting("KAFKA_BOOTSTRAP_SERVERS"), kafkaErr))
	}
	return kafkaClient
}

// AdoptionsHandler is the native handler of Adoptions: publish, lookup, over a Kafka topic.
type AdoptionsHandler struct{}

// NewAdoptionsHandler makes the native handler the generated tests use.
func NewAdoptionsHandler() Adoptions {
	return &AdoptionsHandler{}
}

type adoptionRecord struct {
	Pet      int64  `json:"pet"`
	PetName  string `json:"petName"`
	Customer string `json:"customer"`
}

func (handler *AdoptionsHandler) Publish(value0 Adoption) {
	defer observeOperation("publish", "service-publishes-adoptions")
	value, _ := json.Marshal(adoptionRecord(value0))
	key := []byte(strconv.FormatInt(value0.Pet, 10))
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	record := &kgo.Record{Topic: topic, Partition: 0, Key: key, Value: value}
	if err := kafka().ProduceSync(ctx, record).FirstErr(); err != nil {
		panic(fmt.Sprintf("publish adoption of pet %d: %v", value0.Pet, err))
	}
	written.Store(value0.Pet, record.Offset)
}

func (handler *AdoptionsHandler) Lookup(value0 int64) LawSpecMaybe[Adoption] {
	defer observeOperation("lookup", "service-publishes-adoptions")
	from := int64(0)
	if offset, ok := written.Load(value0); ok {
		from = offset.(int64)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	ends, err := kadm.NewClient(kafka()).ListEndOffsets(ctx, topic)
	if err != nil {
		panic(fmt.Sprintf("lookup pet %d: %v", value0, err))
	}
	end, _ := ends.Lookup(topic, 0)
	if end.Err != nil {
		panic(fmt.Sprintf("lookup pet %d: %v", value0, end.Err))
	}
	if from >= end.Offset {
		return LawSpecAbsent[Adoption]()
	}
	reader, err := kgo.NewClient(
		kgo.SeedBrokers(strings.Split(setting("KAFKA_BOOTSTRAP_SERVERS"), ",")...),
		kgo.ClientID("calm-shop-reader"),
		kgo.ConsumePartitions(map[string]map[int32]kgo.Offset{topic: {0: kgo.NewOffset().At(from)}}),
	)
	if err != nil {
		panic(fmt.Sprintf("lookup pet %d: %v", value0, err))
	}
	defer reader.Close()
	key := strconv.FormatInt(value0, 10)
	var found *adoptionRecord
	for next := from; next < end.Offset; {
		fetches := reader.PollFetches(ctx)
		if errs := fetches.Errors(); len(errs) > 0 {
			panic(fmt.Sprintf("lookup pet %d: %v", value0, errs[0].Err))
		}
		fetches.EachRecord(func(record *kgo.Record) {
			next = record.Offset + 1
			if string(record.Key) == key {
				var decoded adoptionRecord
				if json.Unmarshal(record.Value, &decoded) == nil {
					found = &decoded
				}
			}
		})
	}
	if found == nil {
		return LawSpecAbsent[Adoption]()
	}
	return LawSpecPresent(Adoption(*found))
}

// Audit reads every adoption on the topic and returns how many there are, failing on a record that
// is not an adoption. The audit application runs it; it is not part of an ability, so no law
// depends on it.
func Audit() (int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	ends, err := kadm.NewClient(kafka()).ListEndOffsets(ctx, topic)
	if err != nil {
		return 0, err
	}
	end, _ := ends.Lookup(topic, 0)
	if end.Err != nil {
		return 0, end.Err
	}
	reader, err := kgo.NewClient(
		kgo.SeedBrokers(strings.Split(setting("KAFKA_BOOTSTRAP_SERVERS"), ",")...),
		kgo.ClientID("calm-shop-audit"),
		kgo.ConsumePartitions(map[string]map[int32]kgo.Offset{topic: {0: kgo.NewOffset().AtStart()}}),
	)
	if err != nil {
		return 0, err
	}
	defer reader.Close()
	count := 0
	var bad error
	for next := int64(0); next < end.Offset; {
		fetches := reader.PollFetches(ctx)
		if errs := fetches.Errors(); len(errs) > 0 {
			return count, errs[0].Err
		}
		fetches.EachRecord(func(record *kgo.Record) {
			next = record.Offset + 1
			var decoded adoptionRecord
			if err := json.Unmarshal(record.Value, &decoded); err != nil {
				bad = fmt.Errorf("offset %d is not an adoption: %w", record.Offset, err)
			}
			count++
		})
	}
	return count, bad
}
