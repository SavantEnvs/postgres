/*
 * json_parser_fuzzer: feeds arbitrary bytes to the backend's JSON parser
 * (src/common/jsonapi.c) as UTF-8 text, the same entry point OSS-Fuzz's
 * postgresql project fuzzes.  Errors are handled with PG_TRY, as the backend
 * itself does.
 */
#include "postgres.h"

#include "common/jsonapi.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "tcop/tcopprot.h"
#include "utils/memutils.h"

int
LLVMFuzzerInitialize(int *argc, char ***argv)
{
	MemoryContextInit();
	whereToSendOutput = DestNone;
	Log_destination = 0;
	return 0;
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	MemoryContext ctx;
	MemoryContext oldctx;
	volatile JsonParseErrorType rc = JSON_SUCCESS;
	char	   *buffer;

	set_stack_base();

	ctx = AllocSetContextCreate(TopMemoryContext, "fuzz input", ALLOCSET_DEFAULT_SIZES);
	oldctx = MemoryContextSwitchTo(ctx);

	buffer = palloc(size + 1);
	memcpy(buffer, data, size);
	buffer[size] = '\0';

	PG_TRY();
	{
		JsonLexContext *lex = makeJsonLexContextCstringLen(NULL, buffer, size, PG_UTF8, true);

		rc = pg_parse_json(lex, &nullSemAction);
	}
	PG_CATCH();
	{
		FlushErrorState();
		rc = JSON_SEM_ACTION_FAILED;
	}
	PG_END_TRY();

	MemoryContextSwitchTo(oldctx);
	MemoryContextDelete(ctx);

	return rc == JSON_SUCCESS ? 0 : -1;
}
