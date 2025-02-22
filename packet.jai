// packet.jai

Packet :: struct {
  type  : PacketType;
  flags : PacketFlags;
  size  : u32;
  union {
    connect    : ConnectPacket;
    disconnect : DisconnectPacket;
    update     : UpdatePacket;
    ack        : AckPacket;
    accept     : AcceptPacket;
    none       : NonePacket;
  }
}

PacketType :: enum u8 {
  CONNECT;
  DISCONNECT;
  UPDATE;
  ACCEPT;
  ACK;
  NONE;
}

PacketFlags :: enum_flags u8 {
  ClientBound;
  ServerBound;
}

MAX_USERNAME_LEN :: 64;
ClientID :: u8; 

ConnectPacket :: struct {
  username_len: u8;
  username: [MAX_USERNAME_LEN]u8;
}

DisconnectPacket :: struct {
  client_id: ClientID;
}

UpdatePacket :: struct {
  client_id: ClientID;
  counter: int;
}

AcceptPacket :: struct {
  client_id: int;
}

AckPacket :: struct {
  data: int;
}

NonePacket :: struct {
  
}

buffer_from_packet :: (packet: Packet) -> []u8 #must {
  buf: []u8;
  buf.data= talloc(size_of(Packet));
  buf.count = size_of(Packet);
  buf[0] = xx packet.type;
  buf[1] = xx packet.flags;
  u32_into_buffer(buf, 2, packet.size);
  if #complete packet.type == {
   case .CONNECT;     memcpy(*buf[3], *packet.connect,    size_of(ConnectPacket));
   case .DISCONNECT;  memcpy(*buf[3], *packet.disconnect, size_of(DisconnectPacket));
   case .UPDATE;      memcpy(*buf[3], *packet.update,     size_of(UpdatePacket));
   case .ACK;         memcpy(*buf[3], *packet.ack,        size_of(AckPacket));
   case .ACCEPT;      memcpy(*buf[3], *packet.accept,     size_of(AcceptPacket));
   case .NONE;        memcpy(*buf[3], *packet.none,       size_of(NonePacket));
  }

  return buf;
}

packet_from_buffer :: (buffer: []u8) -> Packet {
  packet: Packet;
  packet_type  := buffer[0];
  packet_flags := buffer[1];
  size := u32_from_bytes(*buffer[2]);
  // TODO (brice): feels extremely obvious that we could use a metaprogram
  // to generate this
  if #complete cast(PacketType) packet_type == {
   case .CONNECT;     memcpy(*packet.connect,    *buffer[3], size_of(ConnectPacket));
   case .DISCONNECT;  memcpy(*packet.disconnect, *buffer[3], size_of(DisconnectPacket));
   case .UPDATE;      memcpy(*packet.update,     *buffer[3], size_of(UpdatePacket));
   case .ACK;         memcpy(*packet.ack,        *buffer[3], size_of(AckPacket));
   case .ACCEPT;      memcpy(*packet.accept,     *buffer[3], size_of(AcceptPacket));
   case .NONE;        memcpy(*packet.none,       *buffer[3], size_of(NonePacket));
  }

  return packet;
}

u32_from_bytes :: (buf_ptr: *u8) -> u32 {
  return cast(u32) buf_ptr 
    + (cast(u32) (buf_ptr + 1)) << 8
    + (cast(u32) (buf_ptr + 2)) << 16
    + (cast(u32) (buf_ptr + 3)) << 24;
}

u32_into_buffer :: (buf: []u8, idx: u32, value: u32) {
  assert(buf.count > idx + 3, "bytes don't fit into buffer");
  buf[idx    ] = xx ((value >>  0) & 0x0000_00ff);
  buf[idx + 1] = xx ((value >>  8) & 0x0000_00ff);
  buf[idx + 2] = xx ((value >> 16) & 0x0000_00ff);
  buf[idx + 3] = xx ((value >> 24) & 0x0000_00ff); 
}
