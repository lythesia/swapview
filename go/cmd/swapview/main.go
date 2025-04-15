package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"log"
	"os"
	"sort"
	"strconv"
	"strings"
	"swapview/cmd/swapview/config"
)

func main() {
	Swapview()
}

type SwapInfo struct {
	pid  int
	comm string
	size int
}

func Swapview() {
	lst := getSwapInfoList()
	sort.Slice(lst, func(i, j int) bool {
		return lst[i].size < lst[j].size
	})

	var total int
	fmt.Printf("%7s %9s %s\n", "PID", "SWAP", "COMMAND")
	for _, info := range lst {
		if info.size == 0 {
			continue
		}
		fmt.Printf("%7d %9s %s\n", info.pid, filesize(info.size), info.comm)
		total += info.size
	}
	fmt.Printf("Total: %10s\n", filesize(total))
}

func getSwapInfoList() []SwapInfo {
	var lst []SwapInfo

	path := fmt.Sprintf("%s/proc", config.Prefix)
	dir, err := os.ReadDir(path)
	if err != nil {
		log.Fatalf("Error opening: %v", err)
	}
	for _, file := range dir {
		pid, err := strconv.Atoi(file.Name())
		if err != nil {
			continue
		}
		comm, err := readComm(pid)
		if err != nil {
			continue
		}
		size, err := readSwapSize(pid)
		if err != nil {
			continue
		}
		lst = append(lst, SwapInfo{
			pid:  pid,
			comm: comm,
			size: size,
		})
	}

	return lst
}

var UNIT = [4]byte{'K', 'M', 'G', 'T'}

func filesize(size int) string {
	left := float64(size)
	unit := 0
	for left > 1100 && unit < 4 {
		left /= 1024.0
		unit += 1
	}
	if unit == 0 {
		return fmt.Sprintf("%dB", size)
	} else {
		return fmt.Sprintf("%.1f%ciB", left, rune(UNIT[unit-1]))
	}
}

func readComm(pid int) (string, error) {
	path := fmt.Sprintf("%s/proc/%d/cmdline", config.Prefix, pid)

	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("error opening: %w", err)
	}
	defer file.Close()

	content, err := io.ReadAll(file)
	if err != nil {
		return "", fmt.Errorf("error reading: %w", err)
	}
	return sanitizeComm(content), nil
}

func sanitizeComm(raw []byte) string {
	if len(raw) > 0 {
		raw = bytes.TrimRight(raw, "\x00")
	}
	rep := bytes.ReplaceAll(raw, []byte{0x00}, []byte{' '})
	return string(rep)
}

func readSwapSize(pid int) (int, error) {
	var total int
	path := fmt.Sprintf("%s/proc/%d/smaps", config.Prefix, pid)

	file, err := os.Open(path)
	if err != nil {
		return 0, fmt.Errorf("error opening: %w", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "Swap:") {
			s := strings.TrimSpace(line[5 : len(line)-3])
			size, err := strconv.Atoi(s)
			if err != nil {
				return 0, fmt.Errorf("invalid size: %w", err)
			}
			total += size
		}
	}

	return total * 1024, nil
}
