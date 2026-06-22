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
    
    //combinational logic
    always_comb begin
        s_tready = 1;   //always ready for v1
        valid = '0;     
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
                        //use helper functions in fm24_pkg
                        //check msg_type
                        5'd0: if(!is_valid_msg_type(s_tdata)) next_state = ERR;
                              else valid.msg_type_valid  = 1;
                        //check side
                        5'd1: if(!is_valid_side(s_tdata)) next_state = ERR;
                              else valid.side_valid      = 1;
                        //output valid flag at last byte for each field (except last byte)
                        5'd3: valid.symbol_id_valid  = 1;
                        5'd11: valid.price_valid     = 1;
                        5'd15: valid.qty_valid       = 1;
                        5'd23: begin 
                            //update valid flag
                            valid.seq_valid       = 1; 
                            //check if seq is continuous 
                            if(last_seq != 0 && {seq_sr[23:0], s_tdata} != last_seq + 1)
                                err.seq_error = 1;
                            //move to IDLE
                            next_state = IDLE;
                        end
                    endcase
                end
            ERR:
                //wait until the last byte arrives 
                //move to IDLE to start next parse
                if (s_tvalid && s_tready && byte_count == 23) begin
                    next_state = IDLE;
                end
        endcase
    end
    always_ff @(posedge clk) begin
        //active-low reset
        if(!arstn) begin
            curr_state <= IDLE;
            byte_count <= '0;
            cmd <= '0;
            last_seq <= '0;
        end else begin
            //update curr_state
            curr_state <= next_state;

            if (s_tvalid && s_tready) begin
                //byte_count iterate
                if (byte_count == 5'd23)
                    byte_count <= '0;
                else
                    byte_count <= byte_count + 1;

                //data shifting
                //1 byte -> write in cmd directly
                //more than 1 byte -> higher byte write in shift register, then in last byte count assemble into cmd 
                case (byte_count)
                    5'd0: cmd.msg_type <= s_tdata;          
                    5'd1: cmd.side <= s_tdata;              
                    5'd2: symbol_id_sr <= {symbol_id_sr[7:0], s_tdata}; 
                    5'd3: cmd.symbol_id <= {symbol_id_sr[7:0], s_tdata};
                    5'd8, 5'd9, 5'd10: price_sr <= {price_sr[23:0], s_tdata};
                    5'd11: cmd.price <= {price_sr[23:0], s_tdata};
                    5'd12, 5'd13, 5'd14: qty_sr <= {qty_sr[23:0], s_tdata};
                    5'd15: cmd.qty <= {qty_sr[23:0], s_tdata};
                    5'd20, 5'd21, 5'd22: seq_sr <= {seq_sr[23:0], s_tdata};
                    //last byte: assemble seq in cmd & store in last_seq
                    5'd23: begin
                        cmd.seq  <= {seq_sr[23:0], s_tdata};
                        last_seq <= {seq_sr[23:0], s_tdata};
                    end
                endcase
            end
        end
    end
    
endmodule