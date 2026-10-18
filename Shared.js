.pragma library

// One copy of this file exists per shell process, however many bars (one per
// monitor) instantiate the widget. Each instance polls on its own, so
// without this every notification would arrive once per monitor.

var sent = {}

// True when this instance should send the notification with this key; false
// when another instance already sent the same one within windowMs.
function claim(key, nowMs, windowMs) {
  for (var k in sent) if (nowMs - sent[k] > windowMs) delete sent[k]
  if (key in sent) return false
  sent[key] = nowMs
  return true
}
