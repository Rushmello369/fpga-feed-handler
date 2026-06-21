module msg_parser
    import fm24_pkg::*;
( 
    input  logic          clk, arstn,
    input  logic          s_tvalid,
    input  logic          s_tlast,
    input  logic [7:0]    s_tdata,
    output logic          s_tready,
    output fm24_valid_t   valid,
    output fm24_err_t     err,
    output fm24_cmd_t     cmd
);

    typedef enum logic [1:0] {
        IDLE    = 2'b00,
        PARSING = 2'b01,
        ERR     = 2'b10
    } state_e;

    state_e curr_state, next_state;
    logic [4:0]  byte_count;
    logic [31:0] last_seq;
    logic [15:0] symbol_id_sr;
    logic [31:0] price_sr;
    logic [31:0] qty_sr;
    logic [31:0] seq_sr;

    always_comb begin
        s_tready = 1;
        valid = '0;
        err = '0;
        next_state = curr_state;

        case (curr_state)
            IDLE:
                if (s_tvalid && s_tready) begin
                    next_state = PARSING;
                end 
            PARSING:
                if (s_tvalid && s_tready) begin
                    case(byte_count)
                        5'd0: if(!is_valid_msg_type(s_tdata)) next_state = ERR;
                              else valid.msg_type_valid  = 1;
                        5'd1: if(!is_valid_side(s_tdata)) next_state = ERR;
                              else valid.side_valid      = 1;
                        5'd3: valid.symbol_id_valid  = 1;
                        5'd11: valid.price_valid     = 1;
                        5'd15: valid.qty_valid       = 1;
                        5'd23: begin 
                            valid.seq_valid       = 1; 
                            if(last_seq != 0 && {seq_sr[23:0], s_tdata} != last_seq + 1)
                                err.seq_error = 1;
                            next_state = IDLE;
                        end
                    endcase
                end
            ERR:
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
            curr_state <= next_state;

            if (s_tvalid && s_tready) begin
                //byte_count iterate
                if (byte_count == 5'd23)
                    byte_count <= '0;
                else
                    byte_count <= byte_count + 1;

                //data shifting
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
                    5'd23: begin
                        cmd.seq  <= {seq_sr[23:0], s_tdata};
                        last_seq <= {seq_sr[23:0], s_tdata};
                    end
                endcase
            end
        end
    end
    
endmodule