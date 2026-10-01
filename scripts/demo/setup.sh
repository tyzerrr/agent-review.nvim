#!/usr/bin/env bash
# デモ用のGoリポジトリを作る（scripts/demo/demo.tape から使用）。
# 使い方: scripts/demo/setup.sh <dir>
set -euo pipefail
dir="${1:?usage: setup.sh <dir>}"
rm -rf "$dir"
mkdir -p "$dir"
cd "$dir"
git init -q -b main
git config user.email demo@example.com
git config user.name demo
git config commit.gpgsign false
mkdir -p internal/store internal/service internal/format

cat > go.mod <<'EOF'
module example.com/demo

go 1.22
EOF
cat > main.go <<'EOF'
package main

import (
	"fmt"

	"example.com/demo/internal/service"
	"example.com/demo/internal/store"
)

func main() {
	s := store.NewMemoryStore()
	svc := service.NewUserService(s)

	svc.Register("alice", "alice@example.com")
	svc.Register("bob", "bob@example.com")

	for _, u := range svc.List() {
		fmt.Println(u.Name, u.Email)
	}
}
EOF
cat > internal/store/store.go <<'EOF'
package store

type User struct {
	ID    int
	Name  string
	Email string
}

type Store interface {
	Save(u User) User
	All() []User
}

type MemoryStore struct {
	users  []User
	nextID int
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{nextID: 1}
}

func (m *MemoryStore) Save(u User) User {
	u.ID = m.nextID
	m.nextID++
	m.users = append(m.users, u)
	return u
}

func (m *MemoryStore) All() []User {
	return m.users
}
EOF
cat > internal/service/user.go <<'EOF'
package service

import "example.com/demo/internal/store"

type UserService struct {
	store store.Store
}

func NewUserService(s store.Store) *UserService {
	return &UserService{store: s}
}

func (s *UserService) Register(name, email string) store.User {
	return s.store.Save(store.User{Name: name, Email: email})
}

func (s *UserService) List() []store.User {
	return s.store.All()
}
EOF
cat > internal/format/legacy.go <<'EOF'
package format

import "strings"

// Upper is no longer used.
func Upper(s string) string {
	return strings.ToUpper(s)
}
EOF
cat > internal/service/util.go <<'EOF'
package service

import "strings"

func normalize(s string) string {
	return strings.TrimSpace(strings.ToLower(s))
}
EOF
git add -A
git commit -q -m initial

# --- ここから「エージェントが加えた変更」 ---
cat > main.go <<'EOF'
package main

import (
	"fmt"
	"log"

	"example.com/demo/internal/service"
	"example.com/demo/internal/store"
)

func main() {
	s := store.NewMemoryStore()
	svc := service.NewUserService(s)

	for _, in := range []struct{ name, email string }{
		{"alice", "Alice@Example.com"},
		{"bob", "bob@example.com"},
		{"alice2", "alice@example.com "},
		{"carol", "not-an-email"},
	} {
		if _, err := svc.Register(in.name, in.email); err != nil {
			log.Printf("register %s: %v", in.name, err)
		}
	}

	for _, u := range svc.List() {
		fmt.Printf("%d %s <%s>\n", u.ID, u.Name, u.Email)
	}
}
EOF
cat > internal/store/store.go <<'EOF'
package store

import "sync"

type User struct {
	ID    int
	Name  string
	Email string
}

type Store interface {
	Save(u User) User
	All() []User
	FindByEmail(email string) (User, bool)
}

type MemoryStore struct {
	mu     sync.RWMutex
	users  []User
	nextID int
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{nextID: 1}
}

func (m *MemoryStore) Save(u User) User {
	m.mu.Lock()
	defer m.mu.Unlock()
	u.ID = m.nextID
	m.nextID++
	m.users = append(m.users, u)
	return u
}

func (m *MemoryStore) All() []User {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]User, len(m.users))
	copy(out, m.users)
	return out
}

func (m *MemoryStore) FindByEmail(email string) (User, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, u := range m.users {
		if u.Email == email {
			return u, true
		}
	}
	return User{}, false
}
EOF
cat > internal/service/user.go <<'EOF'
package service

import (
	"errors"

	"example.com/demo/internal/store"
)

var ErrDuplicateEmail = errors.New("email already registered")

type UserService struct {
	store store.Store
}

func NewUserService(s store.Store) *UserService {
	return &UserService{store: s}
}

func (s *UserService) Register(name, email string) (store.User, error) {
	email = normalize(email)
	if err := validateEmail(email); err != nil {
		return store.User{}, err
	}
	if _, exists := s.store.FindByEmail(email); exists {
		return store.User{}, ErrDuplicateEmail
	}
	return s.store.Save(store.User{Name: name, Email: email}), nil
}

func (s *UserService) List() []store.User {
	return s.store.All()
}
EOF
cat > internal/service/validate.go <<'EOF'
package service

import (
	"errors"
	"strings"
)

var ErrInvalidEmail = errors.New("invalid email")

func validateEmail(email string) error {
	at := strings.Index(email, "@")
	if at <= 0 || at == len(email)-1 || !strings.Contains(email[at:], ".") {
		return ErrInvalidEmail
	}
	return nil
}
EOF
git rm -q internal/format/legacy.go
git mv internal/service/util.go internal/service/normalize.go
