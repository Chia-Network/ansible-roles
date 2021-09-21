package main

import (
	"context"
	"log"
	"net"
	"net/http"
	"os"
	"time"
)

var isReady bool

func main() {
	isReady = false

	go readyLoop()

	log.Fatal(http.ListenAndServe(":53", &Handler{}))
}

// Handler HTTP Handler
type Handler struct{}

func (h *Handler) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if isReady {
		w.WriteHeader(http.StatusOK)
		return
	}

	w.WriteHeader(http.StatusInternalServerError)
}

func readyLoop() {
	hostname, set := os.LookupEnv("DNS_HOSTNAME")
	if !set {
		hostname = "dns-introducer.chia.net"
	}

	r := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			d := net.Dialer{
				Timeout: time.Millisecond * time.Duration(10000),
			}
			return d.DialContext(ctx, network, "127.0.0.1:53")
		},
	}

	for {
		func() {
			ips, err := r.LookupIP(context.TODO(), "ip", hostname)
			if err != nil {
				log.Printf("Fetching dns records failed: %s\n", err.Error())
				isReady = false
				return
			}

			if len(ips) > 0 {
				log.Println("Received at least 1 IP. Ready!")
				isReady = true
				return
			}

			log.Println("Received NO IPs. Not Ready!")
			isReady = false
		}()

		time.Sleep(30 * time.Second)
	}
}
