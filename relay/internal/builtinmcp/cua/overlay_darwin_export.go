//go:build darwin && desktop_cua && cgo

package cua

/*
#include <stdint.h>
*/
import "C"

const (
	synapseDarwinHotkeyTerminate = 1
	synapseDarwinHotkeyDisable   = 2
)

//export synapseDarwinOverlayHotkeyCallback
func synapseDarwinOverlayHotkeyCallback(controllerID C.uintptr_t, action C.int) {
	raw, ok := darwinOverlayControllers.Load(uint64(controllerID))
	if !ok {
		return
	}
	controller, ok := raw.(*darwinOverlayController)
	if !ok || controller == nil || controller.hotkeyHandler == nil {
		return
	}

	switch int(action) {
	case synapseDarwinHotkeyTerminate:
		go controller.hotkeyHandler(overlayHotkeyTerminate)
	case synapseDarwinHotkeyDisable:
		go controller.hotkeyHandler(overlayHotkeyDisableBoot)
	}
}
