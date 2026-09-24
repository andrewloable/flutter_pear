## 0.4.3

No code or behaviour change. Version bump to stay in lockstep with
`flutter_pear` 0.4.3, which fixes a message-loss bug on inbound connections
inside `pear-end/index.js`. The in-memory fake's behaviour is unaffected --
it never modeled Hyperswarm's `info.topics` timing in the first place.

