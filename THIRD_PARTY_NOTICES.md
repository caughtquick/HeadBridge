# Third-party notices and research credits

## Ported and adapted code

HeadBridge incorporates protocol framing and device capability mapping code ported from [podctl](https://github.com/Rockykln/podctl) under the terms of the MIT License:

- Ported Apple Accessory Protocol (AAP) packet framing, opcode definitions, battery report parsing, and setting command builders in `Sources/HeadBridge/Protocol/AAPProtocol.swift` (adapted from `podctl/src/aap.rs`).
- Ported Apple and Beats device capability matrices and Bluetooth Modalias Product ID mappings in `Sources/HeadBridge/Providers/Apple/AppleModelCapabilities.swift` (adapted from `podctl/src/caps.rs`).

The `podctl` MIT license notice is reproduced below:

```text
MIT License

Copyright (c) 2026 pods contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## Protocol research

HeadBridge's Bowers & Wilkins and Sony transports and protocol implementations are written in Swift and distributed under HeadBridge's MIT license. Fact-oriented contributor documentation is available in the:
- [`Bowers & Wilkins RPC notes`](docs/BowersWilkinsRPC.md)
- [`Sony MDR V1 notes`](docs/SonyMDRV1.md)
- [`Sony MDR V2 adapter notes`](docs/SonyMDRV2.md)

Public reverse-engineering projects used to cross-check protocol facts and independently captured traffic include:

- [podctl](https://github.com/Rockykln/podctl) (MIT or Apache-2.0, dual-licensed);
- [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) (MIT);
- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) (AGPL-3.0-or-later);
- [omarchy-bw-headphones](https://github.com/DominicBoettger/omarchy-bw-headphones) (MIT, revision `b04ffb8`), for the Bowers & Wilkins bass/treble command identifiers and per-model ANC values;
- [sony-connect-osx](https://github.com/tanat/sony-connect-osx) (reference only; no license file was present when reviewed).

No source from Gadgetbridge or sony-connect-osx is incorporated into HeadBridge.

HeadBridge is not affiliated with or endorsed by Apple Inc., Sony Corporation, or Bowers & Wilkins.
