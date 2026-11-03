package main

// A WireGuard Bind on connected UDP sockets, one per peer endpoint, instead
// of wireguard-go's default socket bound to every interface. A connected
// socket only ever talks to its one peer, so Windows Firewall sees an
// outgoing flow, like a browser's QUIC, and doesn't ask to let the app
// "communicate on networks". The desktop app only has the hub as a peer.

import (
	"bytes"
	"errors"
	"net"
	"net/netip"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/conn"
)

type dialBind struct {
	mu     sync.Mutex
	conns  map[netip.AddrPort]*net.UDPConn
	recv   chan dialPacket
	closed chan struct{}
}

type dialPacket struct {
	b    []byte
	from netip.AddrPort
}

func newDialBind() *dialBind { return &dialBind{} }

func (b *dialBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed != nil {
		return nil, 0, conn.ErrBindAlreadyOpen
	}
	b.conns = map[netip.AddrPort]*net.UDPConn{}
	b.recv = make(chan dialPacket, 256)
	b.closed = make(chan struct{})
	recv, closed := b.recv, b.closed
	fn := func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		select {
		case p := <-recv:
			sizes[0] = copy(packets[0], p.b)
			eps[0] = &conn.StdNetEndpoint{AddrPort: p.from}
			return 1, nil
		case <-closed:
			return 0, net.ErrClosed
		}
	}
	// The port is the kernel's pick per connection, so there is none to report.
	return []conn.ReceiveFunc{fn}, 0, nil
}

func (b *dialBind) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed == nil {
		return nil
	}
	close(b.closed)
	for _, c := range b.conns {
		c.Close()
	}
	b.conns, b.closed = nil, nil
	return nil
}

func (b *dialBind) SetMark(uint32) error { return nil }

func (b *dialBind) BatchSize() int { return 1 }

func (b *dialBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	ap, err := netip.ParseAddrPort(s)
	if err != nil {
		return nil, err
	}
	return &conn.StdNetEndpoint{AddrPort: ap}, nil
}

func (b *dialBind) Send(bufs [][]byte, ep conn.Endpoint) error {
	e, ok := ep.(*conn.StdNetEndpoint)
	if !ok {
		return conn.ErrWrongEndpointType
	}
	c, err := b.conn(e.AddrPort)
	if err != nil {
		return err
	}
	for _, buf := range bufs {
		if _, err := c.Write(buf); err != nil {
			// The network changed under the socket (new Wi-Fi, cable out):
			// the next send dials again from whatever route is there now.
			b.drop(e.AddrPort, c)
			return err
		}
	}
	return nil
}

func (b *dialBind) conn(to netip.AddrPort) (*net.UDPConn, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed == nil {
		return nil, net.ErrClosed
	}
	if c := b.conns[to]; c != nil {
		return c, nil
	}
	c, err := net.DialUDP("udp", nil, net.UDPAddrFromAddrPort(to))
	if err != nil {
		return nil, err
	}
	b.conns[to] = c
	go b.read(c, to, b.recv, b.closed)
	return c, nil
}

func (b *dialBind) drop(to netip.AddrPort, c *net.UDPConn) {
	b.mu.Lock()
	if b.conns[to] == c {
		delete(b.conns, to)
	}
	b.mu.Unlock()
	c.Close()
}

func (b *dialBind) read(c *net.UDPConn, from netip.AddrPort, recv chan<- dialPacket, closed <-chan struct{}) {
	buf := make([]byte, 65535)
	for {
		n, err := c.Read(buf)
		if err != nil {
			// A connected socket reports the peer's ICMP "port unreachable"
			// as a read error; only a closed socket ends the loop.
			if errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(100 * time.Millisecond)
			continue
		}
		select {
		case recv <- dialPacket{bytes.Clone(buf[:n]), from}:
		case <-closed:
			return
		}
	}
}
