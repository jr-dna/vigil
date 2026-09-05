//
//  Vigil-Bridging-Header.h
//
//  notify.h lives in /usr/include but is not part of any module Swift imports
//  by default, so `notify_register_dispatch` and `notify_cancel` are invisible
//  without this. Same reason PARALLAX bridges CGVirtualDisplay.h.
//
//  If this file ever becomes a problem, nothing here is load-bearing: delete
//  `subscribeToChanges()` from AssertionMonitor and the polling timer keeps
//  the UI correct on its own, just up to five seconds behind.
//

#ifndef VIGIL_BRIDGING_HEADER_H
#define VIGIL_BRIDGING_HEADER_H

#import <notify.h>

#endif /* VIGIL_BRIDGING_HEADER_H */
