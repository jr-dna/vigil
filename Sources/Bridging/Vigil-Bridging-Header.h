//
//  Vigil-Bridging-Header.h
//
//  notify.h lives in /usr/include but is not part of any module Swift imports
//  by default, so `notify_register_dispatch` and `notify_cancel` are invisible
//  without this. Same reason PARALLAX bridges CGVirtualDisplay.h.
//
//  If notify.h ever becomes a problem, it isn't load-bearing: delete
//  `subscribeToChanges()` from AssertionMonitor and the polling timer keeps
//  the UI correct on its own, just up to five seconds behind.
//
//  libproc.h provides `proc_pidpath`, the fallback ProcessInspector uses for a
//  process's executable path when KERN_PROCARGS2 won't describe it. The path
//  is what decides whether a process counts as part of macOS, so it's worth a
//  second way of getting it.
//

#ifndef VIGIL_BRIDGING_HEADER_H
#define VIGIL_BRIDGING_HEADER_H

#import <notify.h>
#import <libproc.h>

#endif /* VIGIL_BRIDGING_HEADER_H */
