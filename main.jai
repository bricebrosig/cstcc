#load "packet.jai";

Client :: struct {
  index       : u16  = 32;     // in the server's client array
  killswitch  : bool = false;  // used to tell the handling thread whether or not to continue processing this

  status: ClientStatus = .CLOSED;  // tells main thread and handling thread whether or not it's ready to be processed

  // client_handler_mutex : Mutex;  // lock this if you're handling the client
  // fd_write_mutex       : Mutex;  // lock this before >>>writing<<< to the fd
  
  socket : Socket = INVALID_SOCKET;       // set this to -1 when there's no client connected
  address: sockaddr_in;

  id : int = -1;
  username : string = "";
  // address_size: int;   // might not need to store this
}

Server :: struct {
  socket: Socket;
  address: sockaddr;
}

ClientStatus :: enum {
  CLOSED;     // no client is connected
  // NOTE (brice): removed this because we don't two way handshake or anything?
  // OPEN;       // a client connection is open with the server but not yet connected *fully*
  CONNECTED;  // this client is conencted (in the lobby) and we are exchanging game info
}

SERVER_ADDRESS :: "127.0.0.1";

main :: () {
  args := get_command_line_arguments();
  if args.count == 1 {
    do_client();
    return;
  }

  if args.count > 2 {
    if args[1] == {
      case "-server";  do_server();
      case "-client";  do_client();
      case;            print("unknown argument!\n");
    }
  }

  return;
}

do_server :: () {
  if !socket_init() {
    print("[ERR] :: couldn't init. Error: %\n", get_last_socket_error());
    return;
  }

  args := get_command_line_arguments();
  if args.count < 3 {
    print("[ERR] :: expected port number after '-server' argument. Exiting...\n");
    return;
  }

  port := cast(u16) string_to_int(args[2]);
  assert(port > 1024 && port < 65536, "port number out of range. expected (1024, 65536), given '%'.\n", port);

  sock := socket(AF_INET, .STREAM, 0);
  if sock == INVALID_SOCKET {
    print("[ERR] :: failed to open socket. Code: %\n", get_last_socket_error());
    return;
  }
  
  print("[INF] :: socket obtained: %\n", sock);
  print("[INF] :: attempting to start server on port %...", port);
  if bind(sock, SERVER_ADDRESS, port, AF_INET) < 0 {
    print("\n[ERR] :: Couldn't not bind to address '%' at port '%'. Error Code: %\n", SERVER_ADDRESS, port, get_last_socket_error());
    return;
  }

  print("bound\n");

  MAX_BACKLOG :: 10;
  if listen(sock, MAX_BACKLOG) < 0 {
    print("[ERR] :: failed to listen. Error code: %\n", get_last_socket_error());
    return;
  }

  print("[INF] :: listening...\n");

  TIMEOUT :: timeval.{1, 0};

  N_CLIENTS :: 8;           
  clients: [N_CLIENTS]Client;
  for *clients {
    it.index = cast(u16) it_index;
    it.status = .CLOSED;
  }

  running := true;
  while running {
    fds: fd_set;
    FD_SET(sock, *fds);

    print("[server] :: before recvfroms\n");

    ////////////////////////////////////////
    // bgb: look for messages from existing clients
    set_blocking(sock, blocking=false);
    for *client, idx: clients {
      if client.status == .CONNECTED {
        recv_buffer: [64]u8;
        sender_addr: sockaddr = ---;
        sender_addr_len :s32 = xx size_of(sockaddr);
        bytes_read := recvfrom(
          client.socket,
          recv_buffer.data,
          recv_buffer.count, 
          cast(MSG) 0,
          xx *client.address,
          xx size_of(sockaddr),
        );

        if bytes_read < 0 {
          print("[ERR] :: failed to from client. Code: %\n", get_last_socket_error());
        }

        if bytes_read == 0 {
          continue;
        }

        client_message: Packet = packet_from_buffer(recv_buffer);
        if #complete client_message.type == {
         case .CONNECT;     #through;
         case .UPDATE;
          payload := client_message.update;
          updating_user_id := payload.client_id;
          updating_data := payload.counter;
          found_match := false;
          for *client, idx: clients {
            if client.id == updating_user_id {
              print("[INF] :: update from user %: %\n", updating_user_id, updating_data);

              response := Packet.{
                type = .ACK,
                flags = .ClientBound,
                size = size_of(AckPacket),
                ack = .{
                  data = updating_data
                }
              };
              pl := buffer_from_packet(response);
              bytes := sendto(client.socket, pl.data, xx pl.count, xx 0, xx *client.address, xx size_of(sockaddr_in));

              if bytes < 0 {
                print("[ERR] :: failed to send message. Code: %\n", get_last_socket_error());
              }
              
              found_match = true;
            }
          }
         case .DISCONNECT;  #through;
         case .ACK;         #through;
         case .ACCEPT;
          assert(false, "should not handle an ack message on the server!");
         case .NONE;        #through;
         case;  assert(false, "cowabunga");
        }
      }
    }

    print("[INF] :: after recvfroms\n");
    
    ////////////////////////////////////////
    // bgb: check if we have new connections
    set_blocking(sock, blocking=true);
    loc_timeout := TIMEOUT;
    n_fds_ready := select(cast(s32) sock + 1, *fds, *fds, *fds, *loc_timeout);

    if n_fds_ready < 0 {
      print("[ERR] :: select() failed. Error code: %\n", get_last_socket_error());
      break;
    } 
    
    if n_fds_ready == 0  {
      continue;
    }
    
    ////////////////////////////////////////
    // bgb: handle the connection
    connected_socket, connected_addr := accept(sock);
    if connected_socket< 0 {
      print("[SERVER] :: failed to accept connection! Error Code: %\n", get_last_socket_error());
      break;
    }

    // decode message
    payload_buffer: [64]u8;
    sender_addr: sockaddr = ---;
    sender_addr_len :s32 = xx size_of(sockaddr);
    bytes_read := recvfrom(
      connected_socket,
      payload_buffer.data,
      payload_buffer.count, 
      cast(MSG) 0,
      *sender_addr,
      *sender_addr_len,
    );

    if bytes_read < 0 {
      print("[SERVER] :: error reading: %\n", get_last_socket_error());
      break;
    }
    print("[INF] :: read % bytes from client\n", bytes_read);
    
    client_message :Packet = packet_from_buffer(payload_buffer);
    if #complete client_message.type == {
     case .CONNECT;
      did_connect := false;

      ////////////////////////////////////////
      // bgb: find a client that is open
      for *client, idx: clients {
        if #complete client.status == {
         case .CLOSED;
          new_user_id := get_new_user_id();
          response := buffer_from_packet(.{
            type = .ACCEPT, 
            flags = .ClientBound,
            size = size_of(ConnectPacket),
            accept = .{
              client_id = new_user_id
            }
          });

          bytes_sent := sendto(
            connected_socket,
            response.data,
            xx response.count,
            cast(MSG) 0,
            *sender_addr,
            size_of(sockaddr)
          );
          
          if bytes_sent < 0 {
            print("[ERR] :: failed to send message back to client. Error code: %\n", get_last_socket_error());
            break;
          }

          client.id       = new_user_id;
          client.index    = xx idx;
          client.status   = .CONNECTED;
          client.socket   = connected_socket;
          client.address  = connected_addr;
          client.username = client_message.connect.username; 

          did_connect = true;
          break;  // we have found a connection, so stop looking at the other clients
         case .CONNECTED;
          // noop
        }
      }

      ////////////////////////////////////////
      // bgb: say we are full
      if !did_connect {
        // TODO (brice): compile-time constant rejection payload
        payload    := payload_from_server_message(.{code = .REJECT});
        bytes_sent := sendto(connected_socket, payload.data, xx payload.count, xx 0, null, 0);
      }
     case .UPDATE;
      updating_user_id := client_message.user_id;
      updating_data := client_message.data;
      found_match := false;
      for *client, idx: clients {
        if client.id == updating_user_id {
          print("[INF] :: update from user %: %\n", updating_user_id, updating_data);
          
          update_response_message := ServerMessage.{
            code = .OK,
            user_id = client.id,
            client_index = client.index,
          };
          payload := payload_from_server_message(update_response_message);
          bytes_sent := sendto(
            client.socket,
            payload.data,
            xx payload.count,
            xx 0,
            xx *client.address,
            xx size_of(sockaddr_in)
          );

          if bytes_sent < 0 {
            print("[ERR] :: failed to send message. Code: %\n", get_last_socket_error());
          }
          
          found_match = true;
        }
      }
      if !found_match  print("[INF] :: couldn't find user id: %\n", updating_user_id);
     
     case .DISCONNECT;  assert(false, "not implemented!");
     case .NONE;        assert(false, "not implemented!");
     case .COUNT;       assert(false, "not implemented!");
    }
  }

  return;
}

do_client :: () {
  my_server: Server;
  my_id: int = -1;
  my_index: int = -1;  // might not need this?

  if !socket_init() {
    print("[ERR] :: socket init failed. Error Code: %\n", get_last_socket_error());
    return;
  }

  args := get_command_line_arguments();
  if args.count < 3 {
    print("[ERR] :: expected port number after '-client' argument. Exiting...\n");
    return;
  }
  
  port := cast(u16) string_to_int(args[2]);
  assert(port > 1024 && port < 65536, "port number out of range. expected (1024, 65536), given '%'.\n", port);

  sock := socket(AF_INET, .SOCK_STREAM, 0);
  if sock == INVALID_SOCKET {
    print("[ERR] :: failed to create socket. Error code: %\n", get_last_socket_error());
    return;
  }

  print("[INF] :: socket obtained: %\n", sock);
  print("[INF] :: connecting to server at '%' on port '%'\n", SERVER_ADDRESS, port);
  if connect(sock, SERVER_ADDRESS, port) != 0 {
    print("[ERR] :: failed to connect to server. error code: %", get_last_socket_error());
  }

  client_message :ClientMessage = .{
    command = .CONNECT,
    username = "sunshinelemur",
  };

  payload := payload_from_client_message(client_message);

  bytes_sent := send(sock, payload.data, xx payload.count, 0);
  if bytes_sent < 0 {
    print("[ERR] :: failed to send message. Error code: %\n", get_last_socket_error());
    return;
  }
  print("[INF] :: sent % bytes to the server.\n", bytes_sent);

  MAX_CLIENT_MESSAGE_SIZE :: 64;
  server_msg_buf: [MAX_CLIENT_MESSAGE_SIZE]u8;
  flags :MSG = 0;
  sender_addr: sockaddr = ---;
  sender_addr_len: s32 = xx size_of(sockaddr);
  maybe_bytes_read := recvfrom(
    sock,
    server_msg_buf.data,
    MAX_CLIENT_MESSAGE_SIZE,
    flags,
    *sender_addr,
    *sender_addr_len
  );

  if maybe_bytes_read < 0 {
    print("[ERR] :: error reading: %", get_last_socket_error());
    return;
  }

  print("[INF] :: read % bytes back from server!\n", maybe_bytes_read);
  server_message := server_message_from_buffer(server_msg_buf);

  print("[INF] :: %\n", server_message);

  spin_client := false;
  if #complete server_message.code == {
   case .ACCEPT;
    my_server.socket = sock;
    my_server.address = sender_addr;
    spin_client = true;
    my_id = server_message.user_id;
    my_index = server_message.client_index;
   case .REJECT;
    print("[INF] :: server rejected connection: server is full\n");
   case .OK;     #through;
   case .BAD;    #through;
   case .COUNT;  
    print("[ERR] :: bad return code!\n");
  }

  ////////////////////////////////////////
  // bgb: client loop
  update_timer := current_time_consensus();
  update_interval := milliseconds_to_apollo(100);
  counter := 69105;
  while spin_client {
    if current_time_consensus() - update_timer > update_interval {
      ////////////////////////////////////////
      // bgb: send update to server
      update_message := ClientMessage.{
        command = .UPDATE,
        user_id = my_id,
        data = counter,
      };
      update_payload := payload_from_client_message(update_message);
      bytes_sent = sendto(
        sock,
        update_payload.data,
        xx update_payload.count,
        xx 0,
        *sender_addr,
        xx size_of(sockaddr)
      );
      if bytes_sent < 0 {
        print("[ERR] :: failed to send update. Code: %\n", get_last_socket_error());
      } else {
        print("[INF] :: updated with %\n", update_message);
      }
      update_timer = current_time_consensus();
    }

    ////////////////////////////////////////
    // bgb: check if the server has a message for us


    ////////////////////////////////////////
    // bgb: do client stuff per frame 
    // counter = counter + 1;
    reset_temporary_storage();
  }
}

connect :: (s: Socket, address: string, port: u16, family: type_of(sockaddr_in.sin_family) = AF_INET) -> s32 {
  server_address: sockaddr_in;
  server_address.sin_family = family;
  // TODO (jon): Eliminate inet_addr() call.
  c_address := to_c_string(address);
  defer free(c_address);
  addr := inet_addr(c_address);

  #if OS == .WINDOWS {
    server_address.sin_addr.S_un.S_addr = addr;
  } else {
    server_address.sin_addr.s_addr = addr;
  }

  server_address.sin_port = htons(port);
  return connect(s, cast(*sockaddr)*server_address, size_of(sockaddr_in));
}


global_user_id := 0;
get_new_user_id :: () -> int {
  global_user_id = global_user_id + 1;
  return global_user_id;
}

BIG_ENDIAN :: #run big_endian();
LITTLE_ENDIAN :: #run !big_endian();

big_endian :: () -> bool {
  x : s16 = 1;
  b : *u8 = cast(*u8) *x;
  if b[0] return false;
  return true;
}

Lock_Result :: enum {
  SUCCESS;
  TIMEOUT;
  ERROR;
}

// try_lock :: (mut: *Mutex) -> Lock_Result {
//   #if OS == .WINDOWS {
//     dword := win.WaitForSingleObject(mut.csection.LockSemaphore, 0);
//     if dword == {
//       case 0x00000000;  lock(mut);  return .SUCCESS;
//       case 0x00000080;  lock(mut);  return .SUCCESS;
//       case 0x00000102;  return .TIMEOUT;
//       case;             return .ERROR;
//     }
//   } else #if (OS == .LINUX || OS == .MACOS || OS == .IOS || OS == .ANDROID) {
//     lock_val := posix.pthread_mutex_trylock(cast(*pthread_mutex_lock) mut.csection);

//     if lock_val == 0      return .SUCCESS;
//     if lock_val == EBUSY  return .TIMEOUT;

//     return .ERROR;
//   }
// }

#import "Basic";
#import "Socket";
// #import "Thread";
#if OS == .WINDOWS {
  win :: #import "Windows";
} else {
  posix :: #import "POSIX";
}