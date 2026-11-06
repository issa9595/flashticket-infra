// ticketpdf : service de génération de billets PDF pour FlashTicket (support de TD).
//
// ATTENTION : l'endpoint /debug/read est VOLONTAIREMENT trop permissif.
// Il sert de cible au test d'évasion du TD1 (confinement AppArmor).
// Ne jamais déployer ce binaire en dehors de la VM du TD.
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var (
	listen  = env("TICKETPDF_LISTEN", ":8443")
	dataDir = env("TICKETPDF_DATA_DIR", "/var/lib/ticketpdf")
	tlsDir  = env("TICKETPDF_TLS_DIR", "/etc/ticketpdf/tls")
	idRe    = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

type order struct {
	OrderID string `json:"order_id"`
	Event   string `json:"event"`
	Holder  string `json:"holder"`
	Seat    string `json:"seat"`
}

// pdfEscape protège les caractères spéciaux d'une chaîne PDF.
func pdfEscape(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `(`, `\(`, `)`, `\)`)
	// Latin-1 simplifié : on remplace ce qui sort de l'ASCII imprimable.
	out := make([]rune, 0, len(s))
	for _, c := range r.Replace(s) {
		if c < 32 || c > 126 {
			c = '?'
		}
		out = append(out, c)
	}
	return string(out)
}

// buildPDF fabrique un PDF d'une page, sans dépendance.
func buildPDF(o order) []byte {
	lines := []string{
		"FLASHTICKET",
		"Billet " + o.OrderID,
		"Evenement : " + o.Event,
		"Titulaire : " + o.Holder,
		"Place : " + o.Seat,
		"Emis le " + time.Now().UTC().Format("2006-01-02 15:04:05 UTC"),
	}
	var content bytes.Buffer
	content.WriteString("BT /F1 22 Tf 60 760 Td 28 TL\n")
	for _, l := range lines {
		fmt.Fprintf(&content, "(%s) Tj T*\n", pdfEscape(l))
	}
	content.WriteString("ET\n")

	objs := []string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
		fmt.Sprintf("<< /Length %d >>\nstream\n%sendstream", content.Len(), content.String()),
		"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
	}
	var b bytes.Buffer
	b.WriteString("%PDF-1.4\n")
	offsets := make([]int, len(objs))
	for i, o := range objs {
		offsets[i] = b.Len()
		fmt.Fprintf(&b, "%d 0 obj\n%s\nendobj\n", i+1, o)
	}
	xref := b.Len()
	fmt.Fprintf(&b, "xref\n0 %d\n0000000000 65535 f \n", len(objs)+1)
	for _, off := range offsets {
		fmt.Fprintf(&b, "%010d 00000 n \n", off)
	}
	fmt.Fprintf(&b, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(objs)+1, xref)
	return b.Bytes()
}

func handleHealth(w http.ResponseWriter, _ *http.Request) {
	// Vérifie que le répertoire de données est bien inscriptible.
	f, err := os.CreateTemp(dataDir, ".health-*")
	if err != nil {
		http.Error(w, "data dir not writable: "+err.Error(), http.StatusServiceUnavailable)
		return
	}
	name := f.Name()
	f.Close()
	os.Remove(name)
	fmt.Fprintln(w, "ok")
}

func handleCreate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST attendu", http.StatusMethodNotAllowed)
		return
	}
	var o order
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&o); err != nil {
		http.Error(w, "JSON invalide", http.StatusBadRequest)
		return
	}
	if !idRe.MatchString(o.OrderID) {
		http.Error(w, "order_id invalide", http.StatusBadRequest)
		return
	}
	path := filepath.Join(dataDir, o.OrderID+".pdf")
	if err := os.WriteFile(path, buildPDF(o), 0o640); err != nil {
		log.Printf("ecriture impossible %s: %v", path, err)
		http.Error(w, "ecriture impossible", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"order_id": o.OrderID, "file": path})
}

func handleGet(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/tickets/"), ".pdf")
	if !idRe.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	data, err := os.ReadFile(filepath.Join(dataDir, id+".pdf"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/pdf")
	w.Write(data)
}

// handleDebugRead : FAILLE VOLONTAIRE (lecture de n'importe quel fichier).
// C'est la cible du test d'évasion : AppArmor doit refuser /etc/shadow.
func handleDebugRead(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Query().Get("path")
	if p == "" {
		http.Error(w, "paramètre path requis", http.StatusBadRequest)
		return
	}
	data, err := os.ReadFile(p)
	if err != nil {
		http.Error(w, "lecture refusée : "+err.Error(), http.StatusForbidden)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(data)
}

// selfSigned génère un certificat éphémère si aucun n'est fourni dans tlsDir.
func selfSigned() (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: "ticketpdf (auto-signe, TD)"},
		DNSNames:     []string{"localhost"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}

func loadCert() (tls.Certificate, string) {
	crt := filepath.Join(tlsDir, "tls.crt")
	key := filepath.Join(tlsDir, "tls.key")
	if _, err := os.Stat(crt); err == nil {
		c, err := tls.LoadX509KeyPair(crt, key)
		if err != nil {
			log.Fatalf("certificat illisible (%s, %s) : %v", crt, key, err)
		}
		return c, "certificat fourni : " + crt
	}
	c, err := selfSigned()
	if err != nil {
		log.Fatal(err)
	}
	return c, "AUCUN certificat dans " + tlsDir + " : certificat auto-signé éphémère (à remplacer en partie C)"
}

func main() {
	// Fichier d'exemple pour le test d'évasion (doit rester lisible).
	sample := filepath.Join(dataDir, "test.pdf")
	if _, err := os.Stat(sample); err != nil {
		err = os.WriteFile(sample, buildPDF(order{"test", "Exemple", "TD1", "A1"}), 0o640)
		if err != nil {
			log.Printf("AVERTISSEMENT : impossible d'écrire %s : %v (droits ? ProtectSystem sans ReadWritePaths ?)", sample, err)
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", handleHealth)
	mux.HandleFunc("/tickets", handleCreate)
	mux.HandleFunc("/tickets/", handleGet)
	mux.HandleFunc("/debug/read", handleDebugRead)

	cert, msg := loadCert()
	log.Println(msg)
	srv := &http.Server{
		Addr:              listen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		TLSConfig: &tls.Config{
			MinVersion:   tls.VersionTLS12,
			Certificates: []tls.Certificate{cert},
		},
	}
	log.Printf("ticketpdf écoute en HTTPS sur %s, données dans %s", listen, dataDir)
	log.Fatal(srv.ListenAndServeTLS("", ""))
}
