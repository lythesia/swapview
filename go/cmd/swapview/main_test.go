package main

import (
	"testing"
)

func Assert(t *testing.T, res bool) {
	t.Helper()
	if !res {
		t.Errorf("assert fail")
	}
}

func AssertEqual[T comparable](t *testing.T, want, got T) {
	t.Helper()
	if got != want {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestReadSwapSize(t *testing.T) {
	total, _ := readSwapSize(149392)
	AssertEqual(t, total, 2662400)
}

func TestReadComm(t *testing.T) {
	comm, _ := readComm(149392)
	Assert(t, len(comm) > 0)
}

func TestFilesize(t *testing.T) {
	s1 := filesize(1000)
	AssertEqual(t, "1000B", s1)

	s2 := filesize(1024)
	AssertEqual(t, "1024B", s2)

	s3 := filesize(1_000_000)
	AssertEqual(t, "976.6KiB", s3)

}
