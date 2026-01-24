# Real Time GO

> Never lose on time again.

After playing a move, get a cooldown period, then play another move.

Two players? Sure! Five players, why not?

## UI

- "Create game" button, no registration, no ratings, just local storage.
- Show ping: 0-50ms green, 50-100ms yellow, 100-150ms orange, 150+ red
- Time kept on client by default, perhaps later radio between client-time and server-time.
- Support pre-moving. Perhaps sequences?

## Server

- BEAM concurrency, should be easy to deploy, Bring Your Own Server.
- Root shows QR code to connect to the server (see [https://github.com/iodevs/qr_code])


## TODO random notes

https://openmoji.org/library/

SSE for updates: https://github.com/rawhat/mist/blob/master/examples/eventz/src/eventz.gleam

    echo '{"id":"test","boardXSize":19,"boardYSize":19,"rules":"tromp-taylor","moves":[["W","Q16"],["W","D4"],["W","C3"]], "maxVisits":1}' | ./katago analysis -model kata1-b6c96-s175395328-d26788732.txt.gz -config analysis_example.cfg

Eventually record the games: use a sidecar recorder Process.

