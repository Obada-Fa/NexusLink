# Phone chart design

Desktop and CPU compare test builds 1.0.47 and 1.0.48. GPU and Network & disk compare the earlier Desktop implementation in `935d864` with 1.0.48. The Flutter captures use the same snapshot at 412 × 915 dp. The colored CPU histories use synthetic per-thread samples for the preview.

### Desktop

CPU activity shows each logical CPU in a stable color with total usage in white. Tap the thread count to see individual traces. Tap the chart or its heading to open the CPU page. The GPU and Memory panels open their monitor pages. Open desktop sits above Favourites.

![Desktop readings before and after](desktop.webp)

### CPU

The processor name and total load sit above the shared chart. CPU 0 through the last logical CPU each have a current percentage and history underneath. Tap a tile to emphasize its trace in the main plot. Tap again to return to Total. Holding the main chart looks up the reading at that host time across the thread tiles and temperature plot. The CPU time window starts at 15 seconds, grows to one minute and then five minutes as samples accumulate.

![CPU load and temperature before and after](cpu.webp)

### GPU

Load, hotspot and power share plot edges and time. The empty interval at the left shows how much history has been collected. The power axis uses the reported cap. Missing sensors get a text label.

![GPU load, temperature and power before and after](gpu.webp)

### Network and disk

Download and Upload use separate labeled plots with identical rate scales. Read and Write use the same arrangement. All four use one five-minute timeline. Rates use binary units. Storage shows an actionable warning when less than ten percent is free.

![Network and disk before and after](transfers.webp)

### Data and acceptance

- Use the existing monitor snapshot and timestamped pushes. Keep irregular sampling, short spikes and the latest real sample. A gap longer than 15 seconds breaks the trace and has no inspection value.
- Use one selected host timestamp per monitor page. Releasing the gesture clears the cursor. Disconnected headline values read “Last reading.”
- Check Desktop drill-down, Back, the CPU process list, and synchronized inspection. Render with normal and double text size and exercise all tabs on narrow phones.
- Check notification taps with two PCs and two outstanding requests in one session, Continue after a nested module, and App info after an agent exits. Publish the signed Android test build with an incremented version code.
