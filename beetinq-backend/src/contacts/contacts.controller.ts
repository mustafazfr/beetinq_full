import { Controller, Post, Body } from '@nestjs/common';
import { ContactsService } from './contacts.service';
import { CreateContactEventDto } from './dto/create-contact-event.dto';

@Controller('contacts')
export class ContactsController {
  constructor(private readonly contactsService: ContactsService) {}

  @Post()
  create(@Body() dto: CreateContactEventDto) {
    return this.contactsService.create(dto);
  }
}
