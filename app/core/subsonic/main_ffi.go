//go:build !standalone

package main

// c-shared（FFI）构建：c-shared 需要 package main 存在一个 main()。
func main() {}
