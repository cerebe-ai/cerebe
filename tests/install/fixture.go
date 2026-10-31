// Offline executable fixtures, built for the host by run.ps1. These model verifier
// decisions; signed.ps1 separately exercises the official pinned verifiers.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func digest(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		os.Exit(1)
	}
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func main() {
	name := strings.TrimSuffix(filepath.Base(os.Args[0]), ".exe")
	args := os.Args[1:]
	if path := os.Getenv("STUB_LOG"); path != "" {
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
		if err != nil {
			panic(err)
		}
		fmt.Fprintln(f, name+" "+strings.Join(args, " "))
		f.Close()
	}
	if name != "cosign" && name != "slsa-verifier" {
		if len(args) > 0 && args[0] == os.Getenv("STUB_FAIL_COMMAND") {
			fmt.Fprintln(os.Stderr, "fixture command failed: "+args[0])
			os.Exit(1)
		}
		if len(args) == 1 && args[0] == "--version" {
			fmt.Println(name + " v8.17.1")
		}
		if len(args) > 0 && args[0] == "doctor" && os.Getenv("STUB_DOCTOR_FAIL") != "" {
			fmt.Fprintln(os.Stderr, "fixture doctor: blocking row")
			os.Exit(1)
		}
		return
	}
	if strings.Contains(filepath.Dir(os.Args[0]), "path-tools") {
		if v := os.Getenv("STUB_REJECT_PATH"); v == name || v == "both" {
			os.Exit(1)
		}
	} else if os.Getenv("STUB_REJECT_PINNED") == name {
		os.Exit(1)
	}
	flags := map[string]string{}
	var files []string
	for i := 1; i < len(args); i++ {
		if strings.HasPrefix(args[i], "--") && i+1 < len(args) {
			flags[args[i]] = args[i+1]
			i++
		} else {
			files = append(files, args[i])
		}
	}
	var proof struct {
		Sum, Identity, Issuer, Source, Branch, Builder string
		Hashes                                         map[string]string
	}
	path := flags["--bundle"]
	if name == "slsa-verifier" {
		path = flags["--provenance-path"]
	}
	b, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(b, &proof) != nil || len(files) == 0 {
		os.Exit(1)
	}
	if name == "cosign" {
		if digest(files[0]) != proof.Sum {
			os.Exit(1)
		}
		if v := flags["--certificate-identity"]; v != "" && v != proof.Identity {
			os.Exit(1)
		}
		if v := flags["--certificate-oidc-issuer"]; v != "" && v != proof.Issuer {
			os.Exit(1)
		}
	} else {
		for flag, want := range map[string]string{"--source-uri": proof.Source, "--source-branch": proof.Branch, "--builder-id": proof.Builder} {
			if v := flags[flag]; v != "" && v != want {
				os.Exit(1)
			}
		}
		for _, file := range files {
			if digest(file) != proof.Hashes[file] {
				os.Exit(1)
			}
		}
	}
}
