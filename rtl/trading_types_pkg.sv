// Planned role: Shared event types, widths, and constants.
package trading_types_pkg;

    // First-version book limits.
    localparam int unsigned MAX_ORDERS   = 1024;
    localparam int unsigned PRICE_LEVELS = 256;

    // Prices use $0.0001 units.
    // Supported range: $150.00 through $152.55.
    localparam logic [31:0] BASE_PRICE = 32'd1500000;
    localparam logic [31:0] TICK_SIZE  = 32'd100;

    typedef logic [63:0] order_id_t;
    typedef logic [31:0] price_t;
    typedef logic [31:0] quantity_t;

    // Multiple orders at one price can exceed a 32-bit total.
    typedef logic [63:0] level_quantity_t;

    // ASCII values match the Python event letters.
    typedef enum logic [7:0] {
        EVENT_ADD     = 8'h41,   // A
        EVENT_EXECUTE = 8'h45,   // E
        EVENT_CANCEL  = 8'h58,   // X
        EVENT_DELETE  = 8'h44    // D
    } event_type_t;

    typedef enum logic [7:0] {
        SIDE_NONE = 8'h00,
        SIDE_BUY  = 8'h42,       // B
        SIDE_SELL = 8'h53        // S
    } side_t;

    // One complete decoded market event.
    typedef struct packed {
        event_type_t event_type;
        order_id_t   order_id;
        quantity_t   quantity;
        side_t       side;
        price_t      price;
    } market_event_t;

    // One stored order.
    typedef struct packed {
        logic      valid;
        order_id_t order_id;
        side_t     side;
        price_t    price;
        quantity_t quantity;
    } order_record_t;

    // Best bid and offer after an update.
    typedef struct packed {
        logic            bid_valid;
        price_t          bid_price;
        level_quantity_t bid_quantity;

        logic            ask_valid;
        price_t          ask_price;
        level_quantity_t ask_quantity;
    } bbo_t;

endpackage : trading_types_pkg