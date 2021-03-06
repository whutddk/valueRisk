
//////////////////////////////////////////////////////////////////////////////////
// Company:    
// Engineer: 29505
// Create Date: 2019-06-30 22:13:07
// Last Modified by:   29505
// Last Modified time: 2019-06-30 23:44:14
// Email: 295054118@whut.edu.cn
// Design Name: e203_ifu_ift2icb.v  
// Module Name:  
// Project Name:  
// Target Devices:  
// Tool Versions:  
// Description:  
// 
// Dependencies:   
// 
// Revision:  
// Revision  
// Additional Comments:   
// 
//////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////
// Company:   
// Engineer: Ruige_Lee
// Create Date: 2019-06-29 09:10:45
// Last Modified by:   Ruige_Lee
// Last Modified time: 2019-06-30 21:08:27
// Email: 295054118@whut.edu.cn
// page: https://whutddk.github.io/
// Design Name: e203_ifu_ift2icb.v  
// Module Name: e203_ifu_ift2icb
// Project Name:   
// Target Devices:   
// Tool Versions:   
// Description:   
// 
// Dependencies:   
// 
// Revision:  
// Revision:    -   
// Additional Comments:  
// 
//
//////////////////////////////////////////////////////////////////////////////////

/*                                                                      
 Copyright 2018 Nuclei System Technology, Inc.                
																																				 
 Licensed under the Apache License, Version 2.0 (the "License");         
 you may not use this file except in compliance with the License.        
 You may obtain a copy of the License at                                 
																																				 
		 http://www.apache.org/licenses/LICENSE-2.0                          
																																				 
	Unless required by applicable law or agreed to in writing, software    
 distributed under the License is distributed on an "AS IS" BASIS,       
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and     
 limitations under the License.                                          
 */                                                                      
																																				 
																																				 
																																				 
//=====================================================================
//
// Designer   : Bob Hu
//
// Description:
//  The ift2icb module convert the fetch request to ICB (Internal Chip bus) 
//  and dispatch to different targets including ITCM, ICache or Sys-MEM.
//
// ====================================================================
`include "e203_defines.v"

module e203_ifu_ift2icb(


	input  itcm_nohold,
	//////////////////////////////////////////////////////////////
	//////////////////////////////////////////////////////////////
	// Fetch Interface to memory system, internal protocol
	//    * IFetch REQ channel
	input  ifu_req_valid, // Handshake valid
	output ifu_req_ready, // Handshake ready
						// Note: the req-addr can be unaligned with the length indicated
						//       by req_len signal.
						//       The targetd (ITCM, ICache or Sys-MEM) ctrl modules 
						//       will handle the unalign cases and split-and-merge works
	input  [`E203_PC_SIZE-1:0] ifu_req_pc, // Fetch PC
	input  ifu_req_seq, // This request is a sequential instruction fetch
	input  ifu_req_seq_rv32, // This request is incremented 32bits fetch
	input  [`E203_PC_SIZE-1:0] ifu_req_last_pc, // The last accessed
																					 // PC address (i.e., pc_r)
														 
	//    * IFetch RSP channel
	output ifu_rsp_valid, // Response valid 
	input  ifu_rsp_ready, // Response ready
	output ifu_rsp_err,   // Response error
						// Note: the RSP channel always return a valid instruction
						//   fetched from the fetching start PC address.
						//   The targetd (ITCM, ICache or Sys-MEM) ctrl modules 
						//   will handle the unalign cases and split-and-merge works
	//output ifu_rsp_replay,   // Response error
	output [32-1:0] ifu_rsp_instr, // Response instruction

	`ifdef E203_HAS_ITCM //{
	//////////////////////////////////////////////////////////////
	//////////////////////////////////////////////////////////////
	// The ITCM address region indication signal
	input [`E203_ADDR_SIZE-1:0] itcm_region_indic,
	// Bus Interface to ITCM, internal protocol called ICB (Internal Chip Bus)
	//    * Bus cmd channel
	output ifu2itcm_icb_cmd_valid, // Handshake valid
	input  ifu2itcm_icb_cmd_ready, // Handshake ready
						// Note: The data on rdata or wdata channel must be naturally
						//       aligned, this is in line with the AXI definition
	output [`E203_ITCM_ADDR_WIDTH-1:0]   ifu2itcm_icb_cmd_addr, // Bus transaction start addr 

	//    * Bus RSP channel
	input  ifu2itcm_icb_rsp_valid, // Response valid 
	output ifu2itcm_icb_rsp_ready, // Response ready
	input  ifu2itcm_icb_rsp_err,   // Response error
						// Note: the RSP rdata is inline with AXI definition
	input  [`E203_ITCM_DATA_WIDTH-1:0] ifu2itcm_icb_rsp_rdata, 

	`endif//}


	`ifdef E203_HAS_MEM_ITF //{
	//////////////////////////////////////////////////////////////
	//////////////////////////////////////////////////////////////
	// Bus Interface to System Memory, internal protocol called ICB (Internal Chip Bus)
	//    * Bus cmd channel
	output ifu2biu_icb_cmd_valid, // Handshake valid
	input  ifu2biu_icb_cmd_ready, // Handshake ready
						// Note: The data on rdata or wdata channel must be naturally
						//       aligned, this is in line with the AXI definition
	output [`E203_ADDR_SIZE-1:0]   ifu2biu_icb_cmd_addr, // Bus transaction start addr 

	//    * Bus RSP channel
	input  ifu2biu_icb_rsp_valid, // Response valid 
	output ifu2biu_icb_rsp_ready, // Response ready
	input  ifu2biu_icb_rsp_err,   // Response error
						// Note: the RSP rdata is inline with AXI definition
	input  [`E203_SYSMEM_DATA_WIDTH-1:0] ifu2biu_icb_rsp_rdata, 
	
	//input  ifu2biu_replay,
	`endif//}


	// The holdup indicating the target is not accessed by other agents 
	// since last accessed by IFU, and the output of it is holding up
	// last value. 
	`ifdef E203_HAS_ITCM //{
	input  ifu2itcm_holdup,
	//input  ifu2itcm_replay,
	`endif//}

	input  clk,
	input  rst_n
	);

`ifndef E203_HAS_ITCM
	`ifndef E203_HAS_MEM_ITF
		!!! ERROR: There is no ITCM and no System interface, where to fetch the instructions? must be wrong configuration.
	`endif//}
`endif//}


/////////////////////////////////////////////////////////
// We need to instante this bypbuf for several reasons:
//   * The IR stage ready signal is generated from EXU stage which 
//      incoperated several timing critical source (e.g., ECC error check, .etc)
//      and this ready signal will be back-pressure to ifetch rsponse channel here
//   * If there is no such bypbuf, the ifetch response channel may stuck waiting
//      the IR stage to be cleared, and this may end up with a deadlock, becuase 
//      EXU stage may access the BIU or ITCM and they are waiting the IFU to accept
//      last instruction access to make way of BIU and ITCM for LSU to access
	wire i_ifu_rsp_valid;
	wire i_ifu_rsp_ready;
	wire i_ifu_rsp_err;
	wire [`E203_INSTR_SIZE-1:0] i_ifu_rsp_instr;
	wire [`E203_INSTR_SIZE+1-1:0]ifu_rsp_bypbuf_i_data;
	wire [`E203_INSTR_SIZE+1-1:0]ifu_rsp_bypbuf_o_data;

	assign ifu_rsp_bypbuf_i_data = {
													i_ifu_rsp_err,
													i_ifu_rsp_instr
													};

	assign {ifu_rsp_err,
					ifu_rsp_instr
													} = ifu_rsp_bypbuf_o_data;

	sirv_gnrl_bypbuf # (
		.DP(1),
		.DW(`E203_INSTR_SIZE+1) 
	) u_e203_ifetch_rsp_bypbuf(
			.i_vld   (i_ifu_rsp_valid),
			.i_rdy   (i_ifu_rsp_ready),

			.o_vld   (ifu_rsp_valid),
			.o_rdy   (ifu_rsp_ready),

			.i_dat   (ifu_rsp_bypbuf_i_data),
			.o_dat   (ifu_rsp_bypbuf_o_data),
	
			.clk     (clk  ),
			.rst_n   (rst_n)
	);

// ===========================================================================
//////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////
/////// The itfctrl scheme introduction
//
// The instruction fetch is very tricky due to two reasons and purposes:
//   (1) We want to save area and dynamic power as much as possible
//   (2) The 32bits-length instructon may be in unaligned address
//
// In order to acheive above-mentioned purposes we define the tricky
//   fetch scheme detailed as below.
//
///////
// Firstly, several phrases are introduced here:
//   * Fetching target: the target address region including
//         ITCM,
//         System Memory Fetch Interface or ICache
//            (Note: Sys Mem and I cache are Exclusive with each other)
//   * Fetching target's Lane: The Lane here means the fetching 
//       target can read out one lane of data at one time. 
//       For example: 
//        * ITCM is 64bits wide SRAM, then it can read out one 
//          aligned 64bits one time (as a lane)
//        * System Memory is 32bits wide bus, then it can read out one 
//          aligned 32bits one time (as a lane)
//        * ICache line is N-Bytes wide SRAM, then it can read out one 
//          aligned N-Bytes one time (as a lane)
//   * Lane holding-up: The read-out Lane could be holding up there
//       For examaple:
//        * ITCM is impelemented as SRAM, the output of SRAM (readout lane)
//          will keep holding up and not change until next time the SRAM
//          is accessed (CS asserted) by new transaction
//        * ICache data ram is impelemented as SRAM, the output of
//          SRAM (readout lane) will keep holding up and not change until
//          next time the SRAM is accessed (CS asserted) by new transaction
//        * The system memory bus is from outside core peripheral or memory
//          we dont know if it will hold-up. Hence, we assume it is not
//          hoding up
//   * Crossing Lane: Since the 32bits-length instruction maybe unaligned with 
//       word address boundry, then it could be in a cross-lane address
//       For example: 
//        * If it is crossing 64bits boundry, then it is crossing ITCM Lane
//        * If it is crossing 32bits boundry, then it is crossing System Memory Lane
//        * If it is crossing N-Bytes boundry, then it is crossing ICache Lane
//   * IR register: The fetch instruction will be put into IR register which 
//       is to be used by decoder to decoding it at EXU stage
//       The Lower 16bits of IR will always be loaded with new coming
//       instructions, but in order to save dynamic power, the higher 
//       16bits IR will only be loaded when incoming instruction is
//       32bits-length (checked by mini-decode module upfront IR 
//       register)
//       Note: The source of IR register Din depends on different
//         situations described in detailed fetching sheme
//   * Leftover buffer: The ifetch will always speculatively fetch a 32bits
//       back since we dont know the instruction to be fetched is 32bits or
//       16bits length (until after it read-back and decoded by mini-decoder).
//       When the new fetch is crossing lane-boundry from current lane
//       to next lane, and if the current lane read-out value is holding up.
//       Then new 32bits instruction to be fetched can be concatated by 
//       "current holding-up lane's upper 16bits" and "next lane's lower 16bits".
//       To make it in one cycle, we push the "current holding-up lane's 
//       upper 16bits" into leftover buffer (16bits) and only issue one ifetch
//       request to memory system, and when it responded with rdata-back, 
//       directly concatate the upper 16bits rdata-back with leftover buffer
//       to become the full 32bits instruction.
//
// The new ifetch request could encounter several cases:
//   * If the new ifetch address is in the same lane portion as last fetch
//     address (current PC):
//     ** If it is crossing the lane boundry, and the current lane rdout is 
//        holding up, then
//        ---- Push current lane rdout's upper 16bits into leftover buffer
//        ---- Issue ICB cmd request with next lane address 
//        ---- After the response rdata back:
//            ---- Put the leftover buffer value into IR lower 16bits
//            ---- Put rdata lower 16bits into IR upper 16bits if instr is 32bits-long
//
//     ** If it is crossing the lane boundry, but the current lane rdout is not 
//        holding up, then
//        ---- First cycle Issue ICB cmd request with current lane address 
//            ---- Put rdata upper 16bits into leftover buffer
//        ---- Second cycle Issue ICB cmd request with next lane address 
//            ---- Put the leftover buffer value into IR lower 16bits
//            ---- Put rdata upper 16bits into IR upper 16bits if instr is 32bits-long
//
//     ** If it is not crossing the lane boundry, and the current lane rdout is 
//        holding up, then
//        ---- Not issue ICB cmd request, just directly use current holding rdata
//            ---- Put aligned rdata into IR (upper 16bits 
//                    only loaded when instr is 32bits-long)
//
//     ** If it is not crossing the lane boundry, but the current lane rdout is 
//        not holding up, then
//        ---- Issue ICB cmd request with current lane address, just directly use
//               current holding rdata
//            ---- Put aligned rdata into IR (upper 16bits 
//                    only loaded when instr is 32bits-long)
//   
//
//   * If the new ifetch address is in the different lane portion as last fetch
//     address (current PC):
//     ** If it is crossing the lane boundry, regardless the current lane rdout is 
//        holding up or not, then
//        ---- First cycle Issue ICB cmd reqeust with current lane address 
//            ---- Put rdata upper 16bits into leftover buffer
//        ---- Second cycle Issue ICB cmd reqeust with next lane address 
//            ---- Put the leftover buffer value into IR lower 16bits
//            ---- Put rdata upper 16bits into IR upper 16bits if instr is 32bits-long
//
//     ** If it is not crossing the lane boundry, then
//        ---- Issue ICB cmd request with current lane address, just directly use
//               current holding rdata
//            ---- Put aligned rdata into IR (upper 16bits 
//                    only loaded when instr is 32bits-long)
//
// ===========================================================================

 

	// The scheme to check if the current accessing PC is same as last accessed ICB address
	//   is as below:
	//     * We only treat this case as true when it is sequentially instruction-fetch
	//         reqeust, and it is crossing the boundry as unalgned (1st 16bits and 2nd 16bits
	//         is crossing the boundry)
	//         ** If the ifetch request is the begining of lane boundry, and sequential fetch,
	//            Then:
	//                 **** If the last time it was prefetched ahead, then this time is accessing
	//                        the same address as last time. Otherwise not.
	//         ** If the ifetch request is not the begining of lane boundry, and sequential fetch,
	//            Then:
	//                 **** It must be access the same address as last time.
	//     * Note: All other non-sequential cases (e.g., flush, branch or replay) are not
	//          treated as this case
	//  

	
	wire ifu_req_hsked = ifu_req_valid & ifu_req_ready;
	wire i_ifu_rsp_hsked = i_ifu_rsp_valid & i_ifu_rsp_ready;
	wire ifu_icb_cmd_valid;
	wire ifu_icb_cmd_ready;
	wire ifu_icb_cmd_hsked = ifu_icb_cmd_valid & ifu_icb_cmd_ready;
	wire ifu_icb_rsp_valid;
	wire ifu_icb_rsp_ready;
	wire ifu_icb_rsp_hsked = ifu_icb_rsp_valid & ifu_icb_rsp_ready;


	/////////////////////////////////////////////////////////////////////////////////
	// Implement the state machine for the ifetch req interface
	//



	localparam ICB_STATE_WIDTH  = 1;
	// State 0: The idle state, means there is no any oustanding ifetch request
	localparam ICB_STATE_IDLE = 1'd0;
	// State 1: Issued first request and wait response
	localparam ICB_STATE_1ST  = 1'd1;

	
	wire [ICB_STATE_WIDTH-1:0] icb_state_nxt;
	wire [ICB_STATE_WIDTH-1:0] icb_state_r;
	wire icb_state_ena;
	wire [ICB_STATE_WIDTH-1:0] state_idle_nxt   ;
	wire [ICB_STATE_WIDTH-1:0] state_1st_nxt    ;

	wire state_idle_exit_ena     ;
	wire state_1st_exit_ena      ;

	// Define some common signals and reused later to save gatecounts
	wire icb_sta_is_idle    = (icb_state_r == ICB_STATE_IDLE   );
	wire icb_sta_is_1st     = (icb_state_r == ICB_STATE_1ST    );

			// **** If the current state is idle,
					// If a new request come, next state is ICB_STATE_1ST
	assign state_idle_exit_ena = icb_sta_is_idle & ifu_req_hsked;
	assign state_idle_nxt      = ICB_STATE_1ST;

			// **** If the current state is 1st,
					// If a response come, exit this state
	assign state_1st_exit_ena  = icb_sta_is_1st & (i_ifu_rsp_hsked);
	assign state_1st_nxt     = 
								(
							// If it need zero or one requests and new req handshaked, then 
							//   next state is ICB_STATE_1ST
							// If it need zero or one requests and no new req handshaked, then
							//   next state is ICB_STATE_IDLE
										ifu_req_hsked  ?  ICB_STATE_1ST 
																		: ICB_STATE_IDLE 
								) ;





	// The state will only toggle when each state is meeting the condition to exit:
	assign icb_state_ena = 
						state_idle_exit_ena | state_1st_exit_ena  ;

	// The next-state is onehot mux to select different entries
	assign icb_state_nxt = 
							({ICB_STATE_WIDTH{state_idle_exit_ena   }} & state_idle_nxt   )
						| ({ICB_STATE_WIDTH{state_1st_exit_ena    }} & state_1st_nxt    )
							;

	sirv_gnrl_dfflr #(ICB_STATE_WIDTH) icb_state_dfflr (icb_state_ena, icb_state_nxt, icb_state_r, clk, rst_n);

	/////////////////////////////////////////////////////////////////////////////////
	// Save the same_cross_holdup flags for this ifetch request to be used


	/////////////////////////////////////////////////////////////////////////////////
	// Save the indicate flags for this ICB transaction to be used
	wire [`E203_PC_SIZE-1:0] ifu_icb_cmd_addr;
	`ifdef E203_HAS_ITCM //{
	wire ifu_icb_cmd2itcm;
	wire icb_cmd2itcm_r;
	sirv_gnrl_dfflr #(1) icb2itcm_dfflr(ifu_icb_cmd_hsked, ifu_icb_cmd2itcm, icb_cmd2itcm_r, clk, rst_n);
	`endif//}
	`ifdef E203_HAS_MEM_ITF //{
	wire ifu_icb_cmd2biu ;
	wire icb_cmd2biu_r;
	sirv_gnrl_dfflr #(1) icb2mem_dfflr (ifu_icb_cmd_hsked, ifu_icb_cmd2biu , icb_cmd2biu_r,  clk, rst_n);
	`endif//}

	
	/////////////////////////////////////////////////////////////////////////////////
	// Generate the ifetch response channel
	// 
	// The ifetch response instr will have 2 sources
	// Please see "The itfctrl scheme introduction" for more details 
	//    * Source #1: The concatenation by {rdata[15:0],leftover}, when
	//          ** the state is in 2ND uop
	//          ** the state is in 1ND uop but it is same-cross-holdup case
	//    * Source #2: The rdata-aligned, when
	//           ** not selecting leftover


	// The fetched instruction from ICB rdata bus need to be aligned by PC LSB bits
	`ifdef E203_HAS_ITCM //{
	wire[31:0] ifu2itcm_icb_rsp_instr = 
										ifu2itcm_icb_rsp_rdata;
		 
	`endif//}

	`ifdef E203_HAS_MEM_ITF //{
	wire[31:0] ifu2biu_icb_rsp_instr = 
										ifu2biu_icb_rsp_rdata;  
	`endif//}

	wire [32-1:0] ifu_icb_rsp_instr = 32'b0
										 `ifdef E203_HAS_ITCM //{
											 | ({32{icb_cmd2itcm_r}} & ifu2itcm_icb_rsp_instr)
										 `endif//}
										 `ifdef E203_HAS_MEM_ITF //{
											 | ({32{icb_cmd2biu_r}}  & ifu2biu_icb_rsp_instr)
										 `endif//}
												;

	wire ifu_icb_rsp_err = 1'b0
										 `ifdef E203_HAS_ITCM //{
											 | (icb_cmd2itcm_r & ifu2itcm_icb_rsp_err)
										 `endif//}
										 `ifdef E203_HAS_MEM_ITF //{
											 | (icb_cmd2biu_r  & ifu2biu_icb_rsp_err)
										 `endif//}
												;

	assign i_ifu_rsp_instr = (ifu_icb_rsp_instr);
	assign i_ifu_rsp_err = (ifu_icb_rsp_err);
	////If the response is to leftover, it is always can be accepted,
	////  so there is no chance to turn over the value, and no need 
	////  to replay, but the data from the response channel (from
	////  ITCM) may be turned over, so need to be replayed
							
	// The ifetch response valid will have 2 sources
	//    Source #1: Did not issue ICB CMD request, and just use last holdup values, then
	//               we generate a fake response valid
	//    Source #2: Did issue ICB CMD request, use ICB response valid. But not each response
	//               valid will be sent to ifetch-response. The ICB response data will put 
	//               into the leftover buffer when:
	//                    It need two uops and itf-state is in 1ST stage (the leftover
	//                    buffer is always ready to accept this)
	wire ifu_icb_rsp2ir_ready;

	wire ifu_icb_rsp2ir_valid = ifu_icb_rsp_valid;
	assign ifu_icb_rsp_ready  = ifu_icb_rsp2ir_ready;
	//

	assign i_ifu_rsp_valid = ifu_icb_rsp2ir_valid;
	assign ifu_icb_rsp2ir_ready = i_ifu_rsp_ready;


	/////////////////////////////////////////////////////////////////////////////////
	// Generate the ICB response channel
	//
	// The ICB response valid to ifetch generated in two cases:
	//    * Case #1: The itf need two uops, and it is in 2ND state response
	//    * Case #2: The itf need only one uop, and it is in 1ND state response
	assign ifu_icb_rsp_valid = 1'b0
										 `ifdef E203_HAS_ITCM //{
											 | (icb_cmd2itcm_r & ifu2itcm_icb_rsp_valid)
										 `endif//}
										 `ifdef E203_HAS_MEM_ITF //{
											 | (icb_cmd2biu_r  & ifu2biu_icb_rsp_valid)
										 `endif//}
												;
 
	 //  //   Explain the performance impacts
	 //  //      because there is a over killing, that the very 1st time ifu to access ITCM it actually
	 //  //      does not need to be replayed, but it just did replay becuase the holdup is not set but we dont care
	 //assign ifu_icb_rsp_replay = 1'b0
	 //                  `ifdef E203_HAS_ITCM //{
	 //                    | (icb_cmd2itcm_r & ifu2itcm_replay)
	 //                  `endif//}
	 //                  `ifdef E203_HAS_MEM_ITF //{
	 //                    | (icb_cmd2biu_r & ifu2biu_replay)
	 //                  `endif//}
	 //                     ;

	/////////////////////////////////////////////////////////////////////////////////
	// Generate the ICB command channel
	//
	// The ICB cmd valid will be generated in two cases:
	//   * Case #1: When the new ifetch-request is coming, and it is not "need zero 
	//              uops"
	//   * Case #2: When the ongoing ifetch is "need 2 uops", and:
	//                ** itf-state is in 1ST state and its response is handshaking (about
	//                    to finish the 1ST state)
	//                ** or it is already in WAIT2ND state
	wire ifu_req_valid_pos;
	assign ifu_icb_cmd_valid = 
									 (ifu_req_valid_pos)
								 ;
										 
	assign ifu_icb_cmd_addr = ( ifu_req_pc);

	/////////////////////////////////////////////////////////////////////////////////
	// Generate the ifetch req channel ready signal
	//
	// Ifu req channel will be ready when the ICB CMD channel is ready and 
	//    * the itf-state is idle
	//    * or only need zero or one uop, and in 1ST state response is backing
	//    * or need two uops, and in 2ND state response is backing
	wire ifu_req_ready_condi = 
								(
										icb_sta_is_idle 
									| ( icb_sta_is_1st & i_ifu_rsp_hsked)
									);
	assign ifu_req_ready     = ifu_icb_cmd_ready & ifu_req_ready_condi; 
	assign ifu_req_valid_pos = ifu_req_valid     & ifu_req_ready_condi; // Handshake valid




	///////////////////////////////////////////////////////
	// Dispatch the ICB CMD and RSP Channel to ITCM and System Memory
	//   according to the address range
	`ifdef E203_HAS_ITCM //{
	assign ifu_icb_cmd2itcm = (ifu_icb_cmd_addr[`E203_ITCM_BASE_REGION] == itcm_region_indic[`E203_ITCM_BASE_REGION]);

	assign ifu2itcm_icb_cmd_valid = ifu_icb_cmd_valid & ifu_icb_cmd2itcm;
	assign ifu2itcm_icb_cmd_addr = ifu_icb_cmd_addr[`E203_ITCM_ADDR_WIDTH-1:0];

	assign ifu2itcm_icb_rsp_ready = ifu_icb_rsp_ready;
	`endif//}

	`ifdef E203_HAS_MEM_ITF //{
	assign ifu_icb_cmd2biu = 1'b1
						`ifdef E203_HAS_ITCM //{
							& ~(ifu_icb_cmd2itcm)
						`endif//}
							;
	wire ifu2biu_icb_cmd_valid_pre  = ifu_icb_cmd_valid & ifu_icb_cmd2biu;
	wire [`E203_ADDR_SIZE-1:0]   ifu2biu_icb_cmd_addr_pre = ifu_icb_cmd_addr[`E203_ADDR_SIZE-1:0];

	assign ifu2biu_icb_rsp_ready = ifu_icb_rsp_ready;

	wire ifu2biu_icb_cmd_ready_pre;
	`endif//}

	assign ifu_icb_cmd_ready = 1'b0
		`ifdef E203_HAS_ITCM //{
				| (ifu_icb_cmd2itcm & ifu2itcm_icb_cmd_ready) 
		`endif//}
		`ifdef E203_HAS_MEM_ITF //{
				| (ifu_icb_cmd2biu  & ifu2biu_icb_cmd_ready_pre ) 
		`endif//}
				;

		`ifdef E203_HAS_MEM_ITF 

		 assign ifu2biu_icb_cmd_addr      = ifu2biu_icb_cmd_addr_pre;
		 assign ifu2biu_icb_cmd_valid     = ifu2biu_icb_cmd_valid_pre;
		 assign ifu2biu_icb_cmd_ready_pre = ifu2biu_icb_cmd_ready;
		`endif//}


endmodule

