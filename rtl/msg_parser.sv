//msg_parser module
//receive Input feed message (AXI4-Stream), parsed them as fm24_cmd and feed it to book_update

module msg_parser
    import fm24_pkg::*;
( 
    input  logic          clk, arstn,  //clock & asynchronous active-low reset
    input  logic          s_tvalid,
    input  logic          s_tlast,
    input  logic [7:0]    s_tdata,
    output logic          s_tready,
    output fm24_valid_t   valid,
    output fm24_err_t     err,
    output fm24_cmd_t     cmd
);

    //fsm state definitions
    typedef enum logic [1:0] {
        IDLE    = 2'b00,    //waiting for a new packet
        PARSING = 2'b01,    //receiving and parsing a valid packet
        ERR     = 2'b10     //packet invalid, drain the reset of the packet
    } state_e;

    state_e curr_state, next_state;
    logic [4:0]  byte_count;    //count from 0-23 (24byte)
    logic [31:0] last_seq;      //store the seq number from previous packet
    //shift registers for assembling multi-byte field
    logic [15:0] symbol_id_sr;  
    logic [31:0] price_sr;
    logic [31:0] qty_sr;
    logic [31:0] seq_sr;
    
    //combinational logic: next_state transitions + error detection
    always_comb begin
        s_tready = 1;   //always ready for v1
        err = '0;
        next_state = curr_state;

        case (curr_state)
            IDLE:
                if (s_tvalid && s_tready) begin
                    //default:move to parsing when handshake is met
                    next_state = PARSING;
                end 
            PARSING:
                if (s_tvalid && s_tready) begin
                    case(byte_count)
                        //check msg_type at byte 0
                        5'd0: if(!is_valid_msg_type(s_tdata)) next_state = ERR;
                        //check side at byte 1
                        5'd1: if(!is_valid_side(s_tdata)) next_state = ERR;
                        //last byte: check seq continuity, return to IDLE
                        5'd23: begin 
                            if(last_seq != 0 && {seq_sr[23:0], s_tdata} != last_seq + 1)
                                err.seq_error = 1;
                            next_state = IDLE;
                        end
                    endcase
                end
            ERR:
                //drain remaining bytes, return to IDLE at end of packet
                if (s_tvalid && s_tready && byte_count == 23) begin
                    next_state = IDLE;
                end
        endcase
    end

    //sequential logic: data assembly + valid pulses (aligned with cmd fields)
    always_ff @(posedge clk) begin
        //active-low reset
        if(!arstn) begin
            curr_state <= IDLE;
            byte_count <= '0;
            cmd        <= '0;
            valid      <= '0;
            last_seq   <= '0;
        end else begin
            //update curr_state
            curr_state <= next_state;

            if (s_tvalid && s_tready) begin
                //default: clear valid every cycle (produces 1-cycle pulses)
                valid <= '0;

                //byte_count iterate
                if (byte_count == 5'd23)
                    byte_count <= '0;
                else
                    byte_count <= byte_count + 1;

                //data shifting + valid pulse (valid now aligned with cmd, both use <=)
                //1 byte -> write in cmd directly
                //more than 1 byte -> higher bytes in shift register, last byte assembles into cmd
                case (byte_count)
                    5'd0: begin 
                        cmd.msg_type <= s_tdata;          
                        valid.msg_type_valid <= 1;
                    end
                    5'd1: begin 
                        cmd.side <= s_tdata;              
                        valid.side_valid <= 1;
                    end
                    5'd2: symbol_id_sr <= {symbol_id_sr[7:0], s_tdata}; 
                    5'd3: begin 
                        cmd.symbol_id <= {symbol_id_sr[7:0], s_tdata};
                        valid.symbol_id_valid <= 1;
                    end
                    5'd8, 5'd9, 5'd10: price_sr <= {price_sr[23:0], s_tdata};
                    5'd11: begin 
                        cmd.price <= {price_sr[23:0], s_tdata};
                        valid.price_valid <= 1;
                    end
                    5'd12, 5'd13, 5'd14: qty_sr <= {qty_sr[23:0], s_tdata};
                    5'd15: begin 
                        cmd.qty <= {qty_sr[23:0], s_tdata};
                        valid.qty_valid <= 1;
                    end
                    5'd20, 5'd21, 5'd22: seq_sr <= {seq_sr[23:0], s_tdata};
                    //last byte: assemble seq into cmd, store in last_seq, pulse valid
                    5'd23: begin
                        cmd.seq  <= {seq_sr[23:0], s_tdata};
                        last_seq <= {seq_sr[23:0], s_tdata};
                        valid.seq_valid <= 1;
                    end
                endcase
            end
        end
    end
    
endmodule