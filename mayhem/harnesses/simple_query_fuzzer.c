/*
 * simple_query_fuzzer: feeds arbitrary bytes to the backend's SQL grammar
 * (raw_parser, RAW_PARSE_DEFAULT: a semicolon-separated list of commands) and
 * exercises the resulting raw parse tree with the node support functions
 * (nodeToString, copyObject, equal).  Parse errors are handled with PG_TRY, as
 * the backend itself does.
 *
 * Nothing here needs a database: semantic analysis and planning read the
 * system catalogs, which do not exist in this process, so they are out of scope.
 */
#include "postgres.h"

#include "miscadmin.h"
#include "tcop/tcopprot.h"
#include "nodes/nodes.h"
#include "nodes/pg_list.h"
#include "parser/parser.h"
#include "utils/guc.h"
#include "utils/memutils.h"

int
LLVMFuzzerInitialize(int *argc, char ***argv)
{
	MemoryContextInit();
	InitializeGUCOptions();
	whereToSendOutput = DestNone;
	Log_destination = 0;
	return 0;
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	MemoryContext ctx;
	MemoryContext oldctx;
	volatile bool parsed = false;
	char	   *query;

	set_stack_base();

	ctx = AllocSetContextCreate(TopMemoryContext, "fuzz input", ALLOCSET_DEFAULT_SIZES);
	oldctx = MemoryContextSwitchTo(ctx);

	query = palloc(size + 1);
	memcpy(query, data, size);
	query[size] = '\0';

	PG_TRY();
	{
		List	   *tree = raw_parser(query, RAW_PARSE_DEFAULT);
		List	   *copy = copyObject(tree);

		(void) nodeToString(tree);
		(void) equal(tree, copy);
		parsed = true;
	}
	PG_CATCH();
	{
		FlushErrorState();
	}
	PG_END_TRY();

	MemoryContextSwitchTo(oldctx);
	MemoryContextDelete(ctx);

	return parsed ? 0 : -1;
}
