/*
 * axis_arb2
 * ---------
 * Two-input, frame-ATOMIC arbiter onto one 8-bit AXI-Stream (the UART TX).
 *
 * s0 = feature frames (board_link_tx), higher priority
 * s1 = status frames  (status_reporter)
 *
 * Both producers hold tvalid HIGH for the duration of one whole frame and drop
 * it only at the frame boundary. So "grant a source until its tvalid falls"
 * is exactly frame granularity: once a frame starts it runs to completion and
 * the two frame types can never interleave/tear on the wire. Without this the
 * host would see a 0xA5 feature frame with status bytes spliced into it.
 *
 * Priority only decides who starts when BOTH are waiting and the mux is idle.
 */
module axis_arb2 (
    input  logic       clk,
    input  logic       arstn,

    input  logic [7:0] s0_tdata,
    input  logic       s0_tvalid,
    output logic       s0_tready,

    input  logic [7:0] s1_tdata,
    input  logic       s1_tvalid,
    output logic       s1_tready,

    output logic [7:0] m_tdata,
    output logic       m_tvalid,
    input  logic       m_tready
);

    typedef enum logic [1:0] { IDLE, GRANT0, GRANT1 } state_e;
    state_e state;

    always_ff @(posedge clk) begin
        if (!arstn) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE: begin
                    if      (s0_tvalid) state <= GRANT0;   // features win ties
                    else if (s1_tvalid) state <= GRANT1;
                end
                // hold the grant for the whole frame: the producer keeps
                // tvalid high until its last byte has been accepted
                GRANT0: if (!s0_tvalid) state <= IDLE;
                GRANT1: if (!s1_tvalid) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end

    always_comb begin
        // default: nothing selected
        m_tdata   = 8'h00;
        m_tvalid  = 1'b0;
        s0_tready = 1'b0;
        s1_tready = 1'b0;

        unique case (state)
            GRANT0: begin
                m_tdata   = s0_tdata;
                m_tvalid  = s0_tvalid;
                s0_tready = m_tready;
            end
            GRANT1: begin
                m_tdata   = s1_tdata;
                m_tvalid  = s1_tvalid;
                s1_tready = m_tready;
            end
            default: ;   // IDLE: grant decided on the next edge
        endcase
    end

endmodule
